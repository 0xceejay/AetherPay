# One Python 3.13 function per secret with a 120 second timeout. It runs in the application
# subnets with the application security group, so it reaches Secrets Manager and PostgreSQL
# privately. The environment holds the secret kind and ARN and, for the database function,
# the host, port and database name.
resource "aws_lambda_function" "rotation" {
  for_each = local.rotation_names

  function_name    = each.value
  role             = aws_iam_role.rotation[each.key].arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  filename         = local.rotation_package
  source_code_hash = filebase64sha256(local.rotation_package)
  timeout          = 120
  tags             = local.common_tags

  vpc_config {
    subnet_ids         = var.application_subnet_ids
    security_group_ids = [var.application_security_group_id]
  }

  environment {
    variables = merge({
      SECRET_KIND = each.key
      SECRET_ARN  = aws_secretsmanager_secret.this[each.key].arn
      }, each.key == "database" ? {
      DB_HOST = var.database.host
      DB_PORT = tostring(var.database.port)
      DB_NAME = var.database.name
    } : {})
  }

  depends_on = [aws_iam_role_policy.rotation, aws_kms_key_policy.secrets, aws_secretsmanager_secret_policy.this]
}

# Lets Secrets Manager invoke each function, limited to this account and to that
# function's own secret.
resource "aws_lambda_permission" "secretsmanager" {
  for_each = local.rotation_names

  statement_id   = "AllowSecretsManagerRotation"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rotation[each.key].function_name
  principal      = "secretsmanager.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = aws_secretsmanager_secret.this[each.key].arn
}

# Initial values are seeded before this binding is enabled.
resource "aws_secretsmanager_secret_rotation" "this" {
  for_each = var.enable_rotation ? local.rotation_names : {}

  secret_id           = aws_secretsmanager_secret.this[each.key].id
  rotation_lambda_arn = aws_lambda_function.rotation[each.key].arn
  rotate_immediately  = true

  rotation_rules {
    automatically_after_days = var.rotation_days[each.key]
  }

  depends_on = [aws_lambda_permission.secretsmanager]
}
