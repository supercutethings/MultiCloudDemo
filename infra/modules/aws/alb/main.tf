resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  subnets         = var.public_subnet_ids
  security_groups = var.security_group_ids

  idle_timeout = var.idle_timeout

  # Reject requests with malformed headers (request smuggling hardening).
  drop_invalid_header_fields = true

  # Access logs are deliberately off in dev: another S3 bucket, another few dollars.
  # Enable them in staging/prod, see docs/adr/0003-gateway-at-the-edge.md.

  tags = {
    Name      = "${var.name_prefix}-alb"
    ManagedBy = "terraform"
  }
}

# Without a certificate, terminate plain HTTP so a demo works with a bare DNS name.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.certificate_arn == null ? "forward" : "redirect"

    target_group_arn = var.certificate_arn == null ? var.target_group_arn : null

    dynamic "redirect" {
      for_each = var.certificate_arn == null ? [] : [1]
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

# TLS 1.2+ only; the 2021 policy is the current AWS default and supports TLS 1.3.
resource "aws_lb_listener" "https" {
  count = var.certificate_arn == null ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = var.target_group_arn
  }
}
