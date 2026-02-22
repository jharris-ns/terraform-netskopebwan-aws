  #cloud-config
  password: ${netskope_gw_default_password}
  infiot:
    uri: ${netskope_tenant_url}
    token: ${netskope_gw_activation_key}
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
    # Install SSM agent (not pre-installed on BWAN-SASE-RTM-CLOUD AMI)
    cd /tmp
    curl -so amazon-ssm-agent.deb \
      "https://s3.${aws_region}.amazonaws.com/amazon-ssm-${aws_region}/latest/debian_amd64/amazon-ssm-agent.deb"
    dpkg -i amazon-ssm-agent.deb
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent