"""Terraform CI artifact, provenance, and alert handling. No application secret reads."""

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile


REPOSITORY = "0xceejay/AetherPay"
WORKFLOW = ".github/workflows/terraform-plan.yml"
REGION = "us-east-1"
TF_VERSION = "1.17.1"
PLATFORM = "linux_amd64"
ALGORITHM = "RSASSA_PSS_SHA_256"
MAX_AGE = 86400
PAYLOAD_FILES = ("plan.tfplan", "backend.json", "staging.tfvars.json", "rotation.zip")
BUNDLE_FILES = set(PAYLOAD_FILES) | {"plan.sig", "manifest.json", "manifest.sig"}
LOCK_PATH = "terraform/environments/staging/.terraform.lock.hcl"
PACKAGE_PATH = "terraform/modules/security/.build/rotation.zip"
VARIABLE_KEYS = {
    "project_name", "availability_zones", "application_port", "database", "cache",
    "queue_visibility_timeout_seconds", "queue_max_receive_count",
    "certificate_arn", "health_check_path", "ecr_repository_arn", "image_uri", "task_cpu",
    "task_memory", "capacity", "scaling", "rotation_days", "enable_rotation",
    "rotation_package_path", "tags",
}


class CIError(Exception):
    """An actionable error whose message is safe for workflow logs."""


def require(condition, message):
    if not condition:
        raise CIError(message)


def env(name):
    value = os.environ.get(name, "").strip()
    require(value, f"Configure {name} before running cloud CI; see \"How to launch\" in README.md.")
    return value


def positive(value):
    require(str(value).isdigit() and int(value) > 0, "PR, run, and attempt identifiers must be positive integers.")
    return int(value)


def utcnow():
    return datetime.now(timezone.utc)


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        require(parsed.tzinfo is not None, "Artifact timestamps must include their timezone.")
        return parsed
    except (AttributeError, ValueError, TypeError):
        raise CIError("Invalid artifact timestamp.") from None


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (ValueError, OSError):
        raise CIError("A required CI JSON file is missing or invalid.") from None


def write_json(path, value):
    Path(path).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    Path(path).chmod(0o600)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def output(name, value):
    require("\n" not in str(value) and "\r" not in str(value), "Invalid workflow output.")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            handle.write(f"{name}={value}\n")


def command(arguments, cwd=None):
    result = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True)
    require(result.returncode == 0, f"{arguments[0]} failed; inspect the restricted job diagnostics and regenerate the plan if needed.")
    return result.stdout


def git(repo_root, *arguments):
    return command(["git", *arguments], cwd=repo_root).strip()


def clean_checkout(repo_root):
    require(not git(repo_root, "status", "--porcelain", "--untracked-files=no"), "Tracked source files changed after checkout; generate a new plan/run.")


def terraform_info(repo_root):
    value = json.loads(command(["terraform", "version", "-json"], cwd=repo_root))
    result = {"version": value.get("terraform_version"), "platform": value.get("platform")}
    require(result == {"version": TF_VERSION, "platform": PLATFORM}, "Use Terraform 1.17.1 on linux_amd64 for both plan and apply.")
    return result


def repository_id():
    require(env("GITHUB_REPOSITORY") == REPOSITORY, "This pipeline is configured for 0xceejay/AetherPay.")
    return positive(env("GITHUB_REPOSITORY_ID"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self):
        self.repo = REPOSITORY
        self.token = env("GH_TOKEN")

    def request(self, path, method="GET", body=None, binary=False):
        require(path.startswith(f"/repos/{self.repo}/"), "Unexpected GitHub API path.")
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        data = None if body is None else json.dumps(body).encode()
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request("https://api.github.com" + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
                raw = response.read(64 * 1024 * 1024 + 1)
                require(len(raw) <= 64 * 1024 * 1024, "GitHub response exceeded the CI size limit.")
                return raw if binary else json.loads(raw)
        except urllib.error.HTTPError as error:
            if binary and error.code in {301, 302, 303, 307, 308}:
                # The signed storage URL must never receive the GitHub bearer token.
                target = error.headers.get("Location", "")
                parsed = urllib.parse.urlsplit(target)
                hostname = parsed.hostname or ""
                require(parsed.scheme == "https" and any(hostname.endswith(suffix) for suffix in (
                    ".blob.core.windows.net", ".githubusercontent.com", ".github.com",
                )), "Unexpected artifact storage location.")
                try:
                    with urllib.request.build_opener(NoRedirect).open(target, timeout=60) as response:
                        raw = response.read(64 * 1024 * 1024 + 1)
                    require(len(raw) <= 64 * 1024 * 1024, "Artifact download exceeded the CI size limit.")
                    return raw
                except urllib.error.URLError:
                    raise CIError("Artifact download failed; retry or generate a new plan.") from None
            raise CIError(f"GitHub API request failed (HTTP {error.code}); check access and artifact retention.") from None
        except urllib.error.URLError:
            raise CIError("GitHub API is unavailable; no apply was authorized.") from None

    def get(self, path):
        return self.request(f"/repos/{self.repo}/{path}")

    def pages(self, path, key=None):
        values = []
        for page in range(1, 101):
            separator = "&" if "?" in path else "?"
            response = self.get(f"{path}{separator}per_page=100&page={page}")
            batch = response[key] if key else response
            values.extend(batch)
            if len(batch) < 100:
                return values
        raise CIError("GitHub pagination exceeded the CI limit.")


def check_actor(api):
    actors = {env("GITHUB_ACTOR"), os.environ.get("GITHUB_TRIGGERING_ACTOR", env("GITHUB_ACTOR"))}
    for actor in actors:
        permission = api.get(f"collaborators/{urllib.parse.quote(actor, safe='')}/permission")
        require(permission.get("permission") in {"write", "maintain", "admin"}, "A repository maintainer must select the plan for apply or regeneration.")


def check_pr(api, number, merged):
    pr = api.get(f"pulls/{positive(number)}")
    require(pr.get("base", {}).get("ref") == "main", "The selected PR must target main.")
    require(pr.get("head", {}).get("repo", {}).get("id") == repository_id(), "Cloud CI does not execute fork pull requests.")
    require(bool(pr.get("merged")) == merged, "Select a merged PR for apply/regeneration, or an open PR for PR planning.")
    if not merged:
        require(pr.get("state") == "open" and not pr.get("draft"), "Cloud planning requires an open, ready-for-review PR.")
    return pr


def assert_main(api, repo_root):
    require(env("GITHUB_REF") == "refs/heads/main", "Manual deployment and drift operations run from main only.")
    current = api.get("git/ref/heads/main")["object"]["sha"]
    require(git(repo_root, "rev-parse", "HEAD") == current, "main changed while the run was queued; start a new plan/run.")
    return current


def select_plan(api, commit):
    """Find the pull request merged by a push to main and its newest successful plan run."""
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Invalid commit identifier.")
    # This endpoint returns summary objects with merged_at but no merged flag, so match on the
    # merge commit here and read the full pull request afterwards.
    candidates = [
        pr for pr in api.get(f"commits/{commit}/pulls")
        if pr.get("merged_at") and pr.get("base", {}).get("ref") == "main" and pr.get("merge_commit_sha") == commit
    ]
    require(len(candidates) == 1, "This push to main is not the merge of exactly one pull request, so no apply was authorized. Dispatch the apply workflow manually if you intend one.")
    pr = check_pr(api, candidates[0]["number"], True)
    identity = repository_id()
    head = pr["head"]["sha"]
    runs = api.pages(f"actions/workflows/{Path(WORKFLOW).name}/runs?event=pull_request&head_sha={head}&status=success", "workflow_runs")
    runs = [
        run for run in runs
        if run.get("conclusion") == "success" and run.get("head_sha") == head
        and run.get("repository", {}).get("id") == identity and run.get("head_repository", {}).get("id") == identity
    ]
    require(runs, "No successful plan run exists for the final commit of this pull request. Run the plan, then dispatch the apply workflow manually.")
    run = max(runs, key=lambda item: item["run_started_at"])
    return positive(pr["number"]), positive(run["id"]), positive(run["run_attempt"])


def resolve_apply(args):
    require(env("GITHUB_EVENT_NAME") == "push" and env("GITHUB_REF") == "refs/heads/main", "Automatic apply selection runs only for a push to main.")
    number, run_id, attempt = select_plan(GitHub(), env("GITHUB_SHA"))
    output("pr_number", number)
    output("plan_run_id", run_id)
    output("plan_run_attempt", attempt)
    print(f"Selected PR {number} and plan run {run_id} attempt {attempt}; the signed plan is verified before any apply.")


def check_main(args):
    repository_id()
    clean_checkout(args.repo_root)
    assert_main(GitHub(), args.repo_root)
    print("Checked current main immediately before applying the saved plan.")


def config_values():
    owner = env("AWS_ACCOUNT_ID")
    require(re.fullmatch(r"[0-9]{12}", owner), "AWS_ACCOUNT_ID must be the 12-digit AWS project ID.")
    bucket, key = env("TF_STATE_BUCKET"), env("TF_STATE_KEY")
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket), "Invalid state bucket name.")
    require(key == "staging/terraform.tfstate", "TF_STATE_KEY must select the staging state, staging/terraform.tfstate.")
    try:
        variables = json.loads(env("STAGING_TFVARS_JSON"))
    except ValueError:
        raise CIError("STAGING_TFVARS_JSON must contain a non-secret JSON object.") from None
    require(isinstance(variables, dict) and set(variables) <= VARIABLE_KEYS, "Staging variables contain unsupported fields; never provide secret values.")
    require(isinstance(variables.get("database"), dict) and set(variables["database"]) == {"host", "port", "name"}, "Supply only host, port, and name in the database metadata.")
    require(variables.get("rotation_package_path") is None, "CI uses its verified rotation ZIP; omit rotation_package_path.")
    require(variables.get("enable_rotation", True) is True, "Complete local secret initialization before normal CI deployment.")
    required = {"availability_zones", "database", "certificate_arn", "ecr_repository_arn", "image_uri", "task_cpu", "task_memory", "capacity", "scaling", "rotation_days"}
    require(required <= set(variables), "STAGING_TFVARS_JSON is missing required staging configuration.")
    # The bucket name embeds the project ID; the S3 backend has no owner argument.
    require(bucket.endswith(f"-{owner}-{REGION}"), "TF_STATE_BUCKET must be the bootstrap bucket for AWS_ACCOUNT_ID.")
    backend = {"bucket": bucket, "key": key, "region": REGION, "encrypt": True, "use_lockfile": True}
    return backend, variables


def configure(args):
    args.work_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    backend, variables = config_values()
    write_json(args.work_dir / "backend.json", backend)
    write_json(args.work_dir / "staging.tfvars.json", variables)
    output("backend_file", args.work_dir / "backend.json")
    output("vars_file", args.work_dir / "staging.tfvars.json")


def prepare_plan(args):
    clean_checkout(args.repo_root)
    api = GitHub()
    identity = repository_id()
    event = env("GITHUB_EVENT_NAME")
    require(event in {"pull_request", "workflow_dispatch"}, "Unsupported plan trigger.")
    merged = event == "workflow_dispatch"
    if merged:
        check_actor(api)
    pr = check_pr(api, args.pr, merged)
    source = git(args.repo_root, "rev-parse", "HEAD")
    require(source == env("GITHUB_SHA"), "Checkout must match the workflow's immutable source commit.")
    commit = api.get(f"git/commits/{source}")
    tree = git(args.repo_root, "rev-parse", "HEAD^{tree}")
    require(commit["tree"]["sha"] == tree, "Checkout tree differs from GitHub source metadata.")
    if merged:
        assert_main(api, args.repo_root)
        comparison = api.get(f"compare/{pr['merge_commit_sha']}...{source}")
        require(comparison["status"] in {"ahead", "identical"}, "Selected PR is not part of current main.")
    else:
        require(env("GITHUB_REF") == f"refs/pull/{args.pr}/merge", "PR plans must use GitHub's proposed merge commit.")
        parents = [parent["sha"] for parent in commit.get("parents", [])]
        require(parents == [pr["base"]["sha"], pr["head"]["sha"]], "PR head/base changed; rerun checks for the current proposed merge.")
    context = {
        "schema": 1, "repository": REPOSITORY, "repository_id": identity,
        "environment": "staging", "workflow": WORKFLOW, "event": event,
        "pr_number": args.pr, "pr_head_sha": pr["head"]["sha"], "pr_base_sha": pr["base"]["sha"],
        "pr_merge_sha": pr.get("merge_commit_sha"), "source_sha": source, "source_tree": tree,
        "run_id": positive(env("GITHUB_RUN_ID")), "run_attempt": positive(env("GITHUB_RUN_ATTEMPT")),
    }
    args.work_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    write_json(args.work_dir / "plan-context.json", context)
    for name in ("source_sha", "source_tree", "pr_number"):
        output(name, context[name])
    output("artifact_name", artifact_name(context["run_id"], context["run_attempt"]))


def artifact_name(run_id, attempt):
    return f"terraform-staging-{positive(run_id)}-{positive(attempt)}"


def aws_cli(*arguments):
    value = command(["aws", *arguments, "--region", REGION, "--no-cli-pager", "--output", "json"])
    try:
        return json.loads(value)
    except ValueError:
        raise CIError("AWS returned an invalid CI signing response.") from None


def signing_key():
    arn = env("PLAN_SIGNING_KEY_ARN")
    match = re.fullmatch(r"arn:aws:kms:us-east-1:([0-9]{12}):key/[0-9a-f-]{36}", arn)
    require(match and match.group(1) == env("AWS_ACCOUNT_ID"), "Use an exact signing-key ARN in this project and us-east-1, not an alias.")
    metadata = aws_cli("kms", "describe-key", "--key-id", arn)["KeyMetadata"]
    require(metadata.get("Arn") == arn and metadata.get("KeyUsage") == "SIGN_VERIFY" and metadata.get("KeySpec") == "RSA_3072" and metadata.get("KeyState") == "Enabled", "The plan-signing key must be enabled RSA_3072 SIGN_VERIFY.")
    return arn


def kms_signature(path, signature, key, verify=False):
    with tempfile.TemporaryDirectory(prefix="ci-kms-") as directory:
        message = Path(directory) / "digest.bin"
        message.write_bytes(hashlib.sha256(Path(path).read_bytes()).digest())
        arguments = ["kms", "verify" if verify else "sign", "--key-id", key,
                     "--message", f"fileb://{message}", "--message-type", "DIGEST",
                     "--signing-algorithm", ALGORITHM]
        if verify:
            arguments += ["--signature", f"fileb://{signature}"]
        result = aws_cli(*arguments)
    require(result.get("KeyId") == key and result.get("SigningAlgorithm") == ALGORITHM, "Signing response did not match the approved key and algorithm.")
    if verify:
        require(result.get("SignatureValid") is True, "Artifact signature verification failed; no apply was authorized.")
    else:
        try:
            raw = base64.b64decode(result["Signature"], validate=True)
        except (ValueError, KeyError):
            raise CIError("Invalid KMS signature encoding.") from None
        require(len(raw) == 384, "Unexpected RSA-3072 signature length.")
        Path(signature).write_bytes(raw)


def make_artifact(args):
    clean_checkout(args.repo_root)
    context = read_json(args.work_dir / "plan-context.json")
    require(context["run_id"] == positive(env("GITHUB_RUN_ID")) and context["run_attempt"] == positive(env("GITHUB_RUN_ATTEMPT")), "Plan context belongs to another workflow attempt.")
    require(context["source_sha"] == git(args.repo_root, "rev-parse", "HEAD") and context["source_tree"] == git(args.repo_root, "rev-parse", "HEAD^{tree}"), "Source changed after preparing the plan.")
    destination = args.work_dir / "artifact"
    require(not destination.exists(), "Artifact directory already exists; generate a fresh plan attempt.")
    destination.mkdir(mode=0o700)
    for name in ("plan.tfplan", "backend.json", "staging.tfvars.json"):
        shutil.copyfile(args.work_dir / name, destination / name)
    shutil.copyfile(args.repo_root / PACKAGE_PATH, destination / "rotation.zip")
    key = signing_key()
    manifest = {
        **context, "created_at": utcnow().isoformat(), "terraform": terraform_info(args.repo_root),
        "signing_key_arn": key, "signing_algorithm": ALGORITHM,
        "provider_lock_sha256": digest(args.repo_root / LOCK_PATH),
        "files": {name: digest(destination / name) for name in PAYLOAD_FILES},
    }
    write_json(destination / "manifest.json", manifest)
    kms_signature(destination / "plan.tfplan", destination / "plan.sig", key)
    kms_signature(destination / "manifest.json", destination / "manifest.sig", key)
    output("artifact_name", artifact_name(context["run_id"], context["run_attempt"]))
    output("artifact_dir", destination)
    print("Signed plan and manifest; no state or raw JSON plan is included.")


def safe_extract(raw, destination):
    require(not destination.exists(), "Artifact extraction directory must be new.")
    destination.mkdir(parents=True, mode=0o700)
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            entries = archive.infolist()
            require({entry.filename for entry in entries} == BUNDLE_FILES and len(entries) == len(BUNDLE_FILES), "Artifact contains unexpected, missing, or duplicate files.")
            require(sum(entry.file_size for entry in entries) <= 128 * 1024 * 1024, "Artifact expansion exceeds the CI limit.")
            for entry in entries:
                require(not entry.is_dir() and not (entry.external_attr >> 16 & 0o170000) == 0o120000, "Artifact symlinks/directories are not accepted.")
                (destination / entry.filename).write_bytes(archive.read(entry))
    except (zipfile.BadZipFile, RuntimeError):
        raise CIError("Invalid plan artifact archive.") from None


def validate_bundle(bundle, manifest, expected, repo_root, now=None):
    """Validate only authenticated manifest data, after KMS verification."""
    now = now or utcnow()
    require(manifest.get("schema") == 1 and manifest.get("environment") == "staging", "Unsupported artifact schema/environment.")
    for name in ("repository", "repository_id", "workflow", "run_id", "run_attempt", "pr_number", "source_tree"):
        require(manifest.get(name) == expected[name], f"Artifact {name} does not match the selected run/source.")
    require(manifest.get("signing_key_arn") == env("PLAN_SIGNING_KEY_ARN") and manifest.get("signing_algorithm") == ALGORITHM, "Artifact signing identity changed.")
    created = timestamp(manifest.get("created_at"))
    require(-300 <= (now - created).total_seconds() <= MAX_AGE, "Plan is expired or has an invalid creation time; generate and review a new plan.")
    require(created >= timestamp(expected["run_started_at"]) and created <= timestamp(expected["artifact_created_at"]) + timedelta(minutes=5), "Manifest time is inconsistent with GitHub provenance.")
    require(manifest.get("terraform") == terraform_info(repo_root), "Plan/apply Terraform toolchains differ.")
    require(manifest.get("provider_lock_sha256") == digest(repo_root / LOCK_PATH), "Provider lock file changed; generate a new plan.")
    require(isinstance(manifest.get("files"), dict) and set(manifest["files"]) == set(PAYLOAD_FILES), "Unexpected signed payload list.")
    for name in PAYLOAD_FILES:
        require(digest(bundle / name) == manifest["files"][name], f"Artifact {name} was modified.")
    backend, variables = config_values()
    require(read_json(bundle / "backend.json") == backend and read_json(bundle / "staging.tfvars.json") == variables, "Backend or staging inputs changed; regenerate and review the plan.")


def verify_apply(args):
    clean_checkout(args.repo_root)
    api = GitHub()
    identity = repository_id()
    check_actor(api)
    main = assert_main(api, args.repo_root)
    pr = check_pr(api, args.pr, True)
    run = api.get(f"actions/runs/{args.run_id}/attempts/{args.run_attempt}")
    require(run.get("id") == args.run_id and run.get("run_attempt") == args.run_attempt, "Unexpected plan run/attempt.")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "Apply requires a successful completed plan run.")
    require(run.get("path", "").split("@")[0] == WORKFLOW and run.get("event") in {"pull_request", "workflow_dispatch"}, "Selected run did not originate in the plan workflow.")
    require(run.get("repository", {}).get("id") == identity and run.get("head_repository", {}).get("id") == identity, "Selected plan run belongs to another repository or fork.")
    artifacts = api.pages(f"actions/runs/{args.run_id}/artifacts", "artifacts")
    selected = [artifact for artifact in artifacts if artifact.get("name") == artifact_name(args.run_id, args.run_attempt)]
    require(len(selected) == 1 and not selected[0].get("expired"), "Selected signed artifact is unavailable/expired; generate a new plan.")
    artifact = selected[0]
    require(0 <= (utcnow() - timestamp(artifact["created_at"])).total_seconds() <= MAX_AGE, "Artifact exceeds its one-day approval window.")
    raw = api.request(f"/repos/{REPOSITORY}/actions/artifacts/{positive(artifact['id'])}/zip", binary=True)
    bundle = args.work_dir / "downloaded-artifact"
    safe_extract(raw, bundle)
    key = signing_key()
    kms_signature(bundle / "manifest.json", bundle / "manifest.sig", key, verify=True)
    kms_signature(bundle / "plan.tfplan", bundle / "plan.sig", key, verify=True)
    manifest = read_json(bundle / "manifest.json")
    expected = {
        "repository": REPOSITORY, "repository_id": identity, "workflow": WORKFLOW,
        "run_id": args.run_id, "run_attempt": args.run_attempt, "pr_number": args.pr,
        "source_tree": git(args.repo_root, "rev-parse", "HEAD^{tree}"),
        "run_started_at": run["run_started_at"], "artifact_created_at": artifact["created_at"],
    }
    validate_bundle(bundle, manifest, expected, args.repo_root)
    require(manifest.get("event") == run["event"], "Signed trigger differs from GitHub run provenance.")
    source = manifest.get("source_sha", "")
    require(re.fullmatch(r"[0-9a-f]{40}", source), "Invalid signed source commit.")
    commit = api.get(f"git/commits/{source}")
    require(commit["tree"]["sha"] == manifest["source_tree"], "Signed source tree does not match GitHub commit provenance.")
    require(run.get("head_sha") in {source, manifest.get("pr_head_sha")}, "Signed source does not match the selected workflow run.")
    if run["event"] == "pull_request":
        require(manifest.get("pr_head_sha") == pr["head"]["sha"], "PR head changed after the plan.")
        parents = [parent["sha"] for parent in commit.get("parents", [])]
        require(parents == [manifest.get("pr_base_sha"), manifest["pr_head_sha"]], "Invalid proposed merge provenance.")
        # A run's pull_requests list covers only open PRs and is empty after merge,
        # so resolve the association from the signed PR head commit instead.
        associated = api.get(f"commits/{manifest['pr_head_sha']}/pulls")
        require(any(item.get("number") == args.pr for item in associated), "Selected run was not generated for this PR.")
        require(api.get(f"git/commits/{pr['merge_commit_sha']}")["tree"]["sha"] == manifest["source_tree"], "Actual merged tree differs from the planned tree; regenerate a plan.")
    else:
        comparison = api.get(f"compare/{pr['merge_commit_sha']}...{source}")
        require(comparison["status"] in {"ahead", "identical"}, "Regenerated plan does not include the selected merged PR.")
        require(run.get("head_branch") == "main", "Regenerated plans must originate on main.")
    # Recheck main after downloading/verifying; queued runs do not get an implicit replan.
    require(assert_main(api, args.repo_root) == main, "main advanced while verifying this plan.")
    for name in ("plan.tfplan", "backend.json", "staging.tfvars.json"):
        shutil.copyfile(bundle / name, args.work_dir / name)
    package = args.repo_root / PACKAGE_PATH
    package.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(bundle / "rotation.zip", package)
    output("plan_file", args.work_dir / "plan.tfplan")
    output("backend_file", args.work_dir / "backend.json")
    output("vars_file", args.work_dir / "staging.tfvars.json")
    print("Selected signatures, provenance, configuration, and package verified. Apply only the restored binary plan.")


COMMENT_MARKER = "<!-- aetherpay-terraform-plan -->"
# GitHub rejects comment bodies over 65,536 characters.
COMMENT_LIMIT = 60000


def plan_counts(changes):
    """Count changes the way Terraform's plan summary does; replacements add and destroy."""
    add = sum("create" in actions for actions in changes)
    change = sum(actions == ["update"] for actions in changes)
    destroy = sum("delete" in actions for actions in changes)
    return f"Plan: {add} to add, {change} to change, {destroy} to destroy."


def truncate(text, limit):
    if len(text) <= limit:
        return text
    kept = text[:limit].rsplit("\n", 1)[0]
    return f"{kept}\n... [truncated {len(text) - len(kept)} characters; review the full plan in the signed artifact]"


def upsert_comment(api, number, body):
    comments = api.pages(f"issues/{positive(number)}/comments")
    existing = [comment for comment in comments if comment.get("user", {}).get("login") == "github-actions[bot]"
                and str(comment.get("body", "")).startswith(COMMENT_MARKER)]
    if existing:
        api.request(f"/repos/{REPOSITORY}/issues/comments/{positive(existing[-1]['id'])}", method="PATCH", body={"body": body})
        return "Updated"
    api.request(f"/repos/{REPOSITORY}/issues/{positive(number)}/comments", method="POST", body={"body": body})
    return "Posted"


def comment_plan(args):
    context = read_json(args.work_dir / "plan-context.json")
    show = ["terraform", "-chdir=terraform/environments/staging", "show"]
    plan = json.loads(command([*show, "-json", str(args.work_dir / "plan.tfplan")]))
    actions, changes = [], []
    for resource in plan.get("resource_changes", []):
        resource_actions = resource["change"]["actions"]
        if resource_actions != ["no-op"]:
            actions.append(resource_actions)
            address = re.sub(r"[^A-Za-z0-9_.\[\]@:/\"-]", "?", resource["address"])
            changes.append(f"{','.join(resource_actions)} {address}")
    drifted = len(plan.get("resource_drift", []))
    # Terraform's rendered plan. Values marked sensitive are already redacted, and
    # this design never passes secret values through Terraform.
    rendered = command([*show, "-no-color", str(args.work_dir / "plan.tfplan")])
    name = artifact_name(context["run_id"], context["run_attempt"])
    url = f"https://github.com/{REPOSITORY}/actions/runs/{context['run_id']}/attempts/{context['run_attempt']}"
    api = GitHub()
    artifacts = api.pages(f"actions/runs/{context['run_id']}/artifacts", "artifacts")
    selected = [artifact for artifact in artifacts if artifact.get("name") == name and not artifact.get("expired")]
    require(len(selected) == 1, "Upload the signed artifact before publishing its review link.")
    artifact_url = f"https://github.com/{REPOSITORY}/actions/runs/{context['run_id']}/artifacts/{positive(selected[0]['id'])}"
    header = (
        f"{COMMENT_MARKER}\n"
        f"### Terraform staging plan — run [{context['run_id']}, attempt {context['run_attempt']}]({url})\n\n"
        f"Source: `{context['source_sha']}`; tree: `{context['source_tree']}`.\n\n"
        f"**{plan_counts(actions)}**"
        + (f" {drifted} resource(s) changed outside Terraform since the last apply." if drifted else "")
        + "\n\n"
        f"````text\n{truncate(chr(10).join(changes) or 'No resource changes.', 10000)}\n````\n\n"
    )
    footer = (
        "\n\nApply only the signed binary plan from artifact "
        f"[{name}]({artifact_url}). The plan, manifest, configuration, and Lambda package "
        "are signed and bound together; artifact retention is one day. This comment is "
        "updated for each new plan of this PR."
    )
    details_open = "<details><summary>Full Terraform plan output</summary>\n\n````text\n"
    details_close = "\n````\n</details>"
    room = COMMENT_LIMIT - len(header) - len(footer) - len(details_open) - len(details_close)
    body = header + details_open + truncate(rendered.strip(), room) + details_close + footer
    print(f"{upsert_comment(api, context['pr_number'], body)} the Terraform plan comment and signed artifact reference.")


def drift_payload(exit_code):
    require(exit_code in {0, 1, 2}, "Unexpected Terraform drift exit code.")
    if exit_code == 0:
        return None
    status = "execution error" if exit_code == 1 else "drift detected"
    run_id = positive(env("GITHUB_RUN_ID"))
    commit = env("GITHUB_SHA")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Invalid drift commit identifier.")
    return {"text": f"AetherPay staging: {status} (Terraform exit {exit_code}).\nCommit: {commit}\nhttps://github.com/{REPOSITORY}/actions/runs/{run_id}"}


def alert_drift(args):
    payload = drift_payload(args.exit_code)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        summary = payload["text"] if payload else "AetherPay staging: clean (Terraform exit 0)."
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(summary + "\n")
    if payload is None:
        print("Staging drift check is clean (exit 0).")
        return
    webhook = env("SLACK_WEBHOOK_URL")
    parsed = urllib.parse.urlsplit(webhook)
    require(parsed.scheme == "https" and parsed.hostname in {"hooks.slack.com", "hooks.slack-gov.com"} and parsed.path.startswith("/services/"), "Configure a valid Slack incoming webhook.")
    request = urllib.request.Request(webhook, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            require(response.status == 200, "Slack did not accept the drift alert.")
    except urllib.error.URLError:
        raise CIError("Slack delivery failed; inspect the workflow result. The webhook URL was not logged.") from None
    print("Sent a metadata-only Slack alert.")
    require(args.exit_code != 1, "Terraform drift execution failed (exit 1); see the restricted workflow diagnostics.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    for name, function in [("config", configure), ("prepare-plan", prepare_plan), ("make-artifact", make_artifact), ("verify-apply", verify_apply), ("check-main", check_main), ("resolve-apply", resolve_apply), ("comment-plan", comment_plan), ("alert-drift", alert_drift)]:
        child = sub.add_parser(name)
        child.set_defaults(function=function)
        if name not in {"alert-drift", "check-main", "resolve-apply"}:
            child.add_argument("--work-dir", type=Path, required=True)
        if name in {"prepare-plan", "make-artifact", "verify-apply", "check-main"}:
            child.add_argument("--repo-root", type=Path, required=True)
        if name in {"prepare-plan", "verify-apply"}:
            child.add_argument("--pr", type=positive, required=True)
        if name == "verify-apply":
            child.add_argument("--run-id", type=positive, required=True)
            child.add_argument("--run-attempt", type=positive, required=True)
        if name == "alert-drift":
            child.add_argument("--exit-code", type=int, choices=[0, 1, 2], required=True)
    try:
        args = parser.parse_args()
        args.function(args)
    except CIError as error:
        print(f"CI stopped: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # SDK/tool diagnostics may include state values, tokens, or signed URLs.
        print("CI stopped: invalid configuration/artifact or unavailable tooling. No apply was authorized.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
