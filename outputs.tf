output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "ecr_repo_url" {
  value = aws_ecr_repository.app.repository_url
}

output "app_bucket_name" {
  value = aws_s3_bucket.app.bucket
}

output "ec2_public_ip" {
  value = aws_instance.utility.public_ip
}
