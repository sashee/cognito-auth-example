provider "aws" {
}

data "aws_region" "current" {
}

resource "random_id" "id" {
  byte_length = 8
}

# frontend

resource "aws_s3_bucket" "bucket" {
  force_destroy = "true"
}

locals {
  # Maps file extensions to mime types
  # Need to add more if needed
  mime_type_mappings = {
    html = "text/html",
    js   = "text/javascript",
    mjs  = "text/javascript",
    css  = "text/css"
  }
}

resource "aws_s3_bucket_object" "frontend_object" {
  for_each = fileset("${path.module}/frontend", "*")
  key      = each.value
  source   = "${path.module}/frontend/${each.value}"
  bucket   = aws_s3_bucket.bucket.bucket

  etag          = filemd5("${path.module}/frontend/${each.value}")
  content_type  = local.mime_type_mappings[concat(regexall("\\.([^\\.]*)$", each.value), [[""]])[0][0]]
  cache_control = "no-store, max-age=0"
}

resource "aws_s3_bucket_object" "frontend_config" {
  key     = "config.js"
  content = <<EOF
export const cognitoLoginUrl = "https://${aws_cognito_user_pool_domain.domain.domain}.auth.${data.aws_region.current.name}.amazoncognito.com";
export const clientId = "${aws_cognito_user_pool_client.client.id}";
EOF
  bucket  = aws_s3_bucket.bucket.bucket

  content_type  = "text/javascript"
  cache_control = "no-store, max-age=0"
}

resource "aws_cloudfront_distribution" "distribution" {
  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name
    origin_id   = "s3"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.OAI.cloudfront_access_identity_path
    }
  }
  origin {
    domain_name = replace(aws_apigatewayv2_api.api.api_endpoint, "/^https?://([^/]*).*/", "$1")
    origin_id   = "apigw"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "apigw"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      headers      = ["Authorization"]
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "https-only"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "OAI_policy" {
  bucket = aws_s3_bucket.bucket.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.OAI.iam_arn]
    }
  }
}

resource "aws_cloudfront_origin_access_identity" "OAI" {
}

output "domain" {
  value = aws_cloudfront_distribution.distribution.domain_name
}

## Cognito

# auto-confirm trigger

data "archive_file" "auto_confirm_lambda_code" {
  type        = "zip"
  output_path = "/tmp/${random_id.id.hex}-auto_confirm_lambda.zip"
  source {
    content  = <<EOF
module.exports.handler = async (event) => {
	event.response.autoConfirmUser = true;
	return event;
};
EOF
    filename = "index.js"
  }
}

resource "aws_lambda_function" "auto_confirm" {
  function_name = "auto-confirm-${random_id.id.hex}-function"

  filename         = data.archive_file.auto_confirm_lambda_code.output_path
  source_code_hash = data.archive_file.auto_confirm_lambda_code.output_base64sha256

  handler = "index.handler"
  runtime = "nodejs14.x"
  role    = aws_iam_role.auto_confirm.arn
}

resource "aws_iam_role" "auto_confirm" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
	{
	  "Action": "sts:AssumeRole",
	  "Principal": {
			"Service": "lambda.amazonaws.com"
	  },
	  "Effect": "Allow"
	}
  ]
}
EOF
}

resource "aws_lambda_permission" "auto_confirm" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_confirm.arn
  principal     = "cognito-idp.amazonaws.com"

  source_arn = aws_cognito_user_pool.pool.arn
}

resource "aws_cognito_user_pool" "pool" {
  name = "test-${random_id.id.hex}"
  lambda_config {
    pre_sign_up = aws_lambda_function.auto_confirm.arn
  }
}

resource "aws_cognito_user_pool_domain" "domain" {
  domain       = "test-${random_id.id.hex}"
  user_pool_id = aws_cognito_user_pool.pool.id
}

resource "aws_cognito_user_pool_client" "client" {
  name = "client"

  user_pool_id                         = aws_cognito_user_pool.pool.id
  allowed_oauth_flows                  = ["code"]
  callback_urls                        = ["https://${aws_cloudfront_distribution.distribution.domain_name}"]
  allowed_oauth_scopes                 = ["openid"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]
}

data "external" "backend_build" {
  program = ["bash", "-c", <<EOT
(npm ci) >&2 && echo "{\"dest\": \".\"}"
EOT
  ]
  working_dir = "${path.module}/backend"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/${random_id.id.hex}-lambda.zip"
  source_dir  = "${data.external.backend_build.working_dir}/${data.external.backend_build.result.dest}"
}

resource "aws_lambda_function" "backend" {
  function_name = "backend-${random_id.id.hex}-function"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "index.handler"
  runtime = "nodejs14.x"
  role    = aws_iam_role.lambda_exec.arn
  environment {
    variables = {
      CLIENT_ID    = aws_cognito_user_pool_client.client.id
      USER_POOL_ID = aws_cognito_user_pool.pool.id
    }
  }
}

data "aws_iam_policy_document" "lambda_exec_role_policy" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

resource "aws_cloudwatch_log_group" "loggroup" {
  name              = "/aws/lambda/${aws_lambda_function.backend.function_name}"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "lambda_exec_role" {
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec_role_policy.json
}

resource "aws_iam_role" "lambda_exec" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
	{
	  "Action": "sts:AssumeRole",
	  "Principal": {
			"Service": "lambda.amazonaws.com"
	  },
	  "Effect": "Allow"
	}
  ]
}
EOF
}

resource "aws_apigatewayv2_api" "api" {
  name          = "api-${random_id.id.hex}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "api" {
  api_id           = aws_apigatewayv2_api.api.id
  integration_type = "AWS_PROXY"

  integration_method     = "POST"
  integration_uri        = aws_lambda_function.backend.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "api" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "$default"

  target = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_stage" "api" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

# Permission
resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
