  #cloud-config
  password: ${netskope_gw_default_password}
  infiot:
    uri: ${netskope_tenant_url}
    token: ${netskope_gw_activation_key}
  runcmd:
  - |
    # Install SSM agent (not pre-installed on BWAN-SASE-RTM-CLOUD AMI)
    cd /tmp
    curl -so amazon-ssm-agent.deb \
      "https://s3.${aws_region}.amazonaws.com/amazon-ssm-${aws_region}/latest/debian_amd64/amazon-ssm-agent.deb"
    dpkg -i amazon-ssm-agent.deb
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent