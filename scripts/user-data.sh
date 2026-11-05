  #cloud-config
  runcmd:
  - |
    # Pin IMDS route to primary ENI so the Netskope overlay (169.254.0.0/16)
    # cannot capture metadata traffic. The /32 host route wins by longest-prefix match.
    PRIMARY_ENI=$(ip -o link show | awk -F': ' '/^2:/{print $2}')
    ip route add 169.254.169.254/32 dev "$PRIMARY_ENI"

    # Make the IMDS route persistent across reboots
    cat > /etc/networkd-dispatcher/routable.d/50-imds-route <<'IMDS'
    #!/bin/bash
    PRIMARY_ENI=$(ip -o link show | awk -F': ' '/^2:/{print $2}')
    ip route replace 169.254.169.254/32 dev "$PRIMARY_ENI"
    IMDS
    chmod 755 /etc/networkd-dispatcher/routable.d/50-imds-route
  - |
    # Fetch credentials from SSM Parameter Store — keeps cleartext out of user-data.
    # Install AWS CLI if the BWAN AMI does not ship it.
    if ! command -v aws &>/dev/null; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y awscli 2>/dev/null || {
        curl -sfLo /tmp/awscliv2.zip \
          "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
          && unzip -q /tmp/awscliv2.zip -d /tmp \
          && /tmp/aws/install --bin-dir /usr/local/bin \
          && rm -rf /tmp/awscliv2.zip /tmp/aws
      }
    fi
    PASSWORD=$(aws ssm get-parameter \
      --name "${ssm_password_path}" \
      --with-decryption \
      --query Parameter.Value \
      --output text \
      --region "${aws_region}")
    TOKEN=$(aws ssm get-parameter \
      --name "${ssm_token_path}" \
      --with-decryption \
      --query Parameter.Value \
      --output text \
      --region "${aws_region}")
    echo "infiot:$PASSWORD" | chpasswd
    infhostd activate -uri "${netskope_tenant_url}" -token "$TOKEN" \
      || echo "Activation failed (gateway may already be activated) — continuing..."
  - |
    # Install SSM agent (not pre-installed on BWAN-SASE-RTM-CLOUD AMI)
    cd /tmp
    for i in $(seq 1 5); do
      curl -sfLo amazon-ssm-agent.deb \
        "https://s3.${aws_region}.amazonaws.com/amazon-ssm-${aws_region}/latest/debian_amd64/amazon-ssm-agent.deb" \
        && break
      echo "SSM agent download attempt $i failed, retrying in 10s..."
      sleep 10
    done
    if [ -f amazon-ssm-agent.deb ]; then
      dpkg -i amazon-ssm-agent.deb
      systemctl enable amazon-ssm-agent
      systemctl start amazon-ssm-agent
    else
      echo "ERROR: Failed to download SSM agent after 5 attempts"
    fi
