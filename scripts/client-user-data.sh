  #cloud-config
  runcmd:
  - |
    # Fetch password from SSM Parameter Store — keeps cleartext out of user-data.
    # Amazon Linux 2023 ships with AWS CLI v2 pre-installed.
    PASSWORD=$(aws ssm get-parameter \
      --name "${ssm_password_path}" \
      --with-decryption \
      --query Parameter.Value \
      --output text \
      --region "${aws_region}")
    echo "ec2-user:$PASSWORD" | chpasswd
