#------------------------------------------------------------------------------
#  GRE Config Module - SSM-based FRR JSON writing + GRE tunnel configuration
#------------------------------------------------------------------------------

#
# SSM Document for FRR config writing + GRE tunnel setup (shared across all gateways)
#
resource "aws_ssm_document" "gre_config" {
  name            = "${replace(var.environment, "-", "_")}_netskope_gre_config"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Write FRR config and configure GRE tunnel on Netskope BWAN gateway"
    parameters = {
      insideIp = {
        type        = "String"
        description = "GRE tunnel inside IP"
      }
      insideMask = {
        type        = "String"
        description = "GRE tunnel inside netmask"
      }
      localIp = {
        type        = "String"
        description = "GRE tunnel local (LAN) IP"
      }
      remoteIp = {
        type        = "String"
        description = "GRE tunnel remote (TGW) IP"
      }
      intfName = {
        type        = "String"
        description = "GRE interface name"
        default     = "gre1"
      }
      mtu = {
        type        = "String"
        description = "GRE tunnel MTU"
        default     = "1300"
      }
      phyIntfname = {
        type        = "String"
        description = "Physical interface name for GRE underlay"
        default     = "enp2s1"
      }
      bgpAsn = {
        type        = "String"
        description = "BGP AS number"
      }
      bgpPeer1 = {
        type        = "String"
        description = "First BGP peer IP (TGW inside)"
      }
      bgpPeer2 = {
        type        = "String"
        description = "Second BGP peer IP (TGW inside)"
      }
      bgpMetric = {
        type        = "String"
        description = "BGP MED metric value"
        default     = "10"
      }
      tgwAsn = {
        type        = "String"
        description = "Transit Gateway BGP ASN (remote-as)"
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "writeFrrConfig"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "set -e",
            "echo 'Writing FRR configuration...'",
            "cat > /infroot/workdir/frrcmds-user.json << 'FRREOF'",
            "{",
            "  \"frrCmdSets\": [",
            "    {",
            "      \"frrCmds\": [",
            "        \"conf t\",",
            "        \"ip community-list standard HA_COMMUNITY permit 47474:47474\"",
            "      ]",
            "    },",
            "    {",
            "      \"frrCmds\": [",
            "        \"conf t\",",
            "        \"ip prefix-list default seq 5 permit 0.0.0.0/0\",",
            "        \"route-map advertise permit 10\",",
            "        \"match ip address prefix-list default\",",
            "        \"route-map set-med-peer permit 10\",",
            "        \"set metric {{ bgpMetric }}\"",
            "      ]",
            "    },",
            "    {",
            "      \"frrCmds\": [",
            "        \"conf t\",",
            "        \"router bgp {{ bgpAsn }}\",",
            "        \"neighbor {{ bgpPeer1 }} remote-as {{ tgwAsn }}\",",
            "        \"neighbor {{ bgpPeer1 }} disable-connected-check\",",
            "        \"neighbor {{ bgpPeer1 }} ebgp-multihop 2\",",
            "        \"neighbor {{ bgpPeer1 }} route-map set-med-peer out\",",
            "        \"neighbor {{ bgpPeer2 }} remote-as {{ tgwAsn }}\",",
            "        \"neighbor {{ bgpPeer2 }} disable-connected-check\",",
            "        \"neighbor {{ bgpPeer2 }} ebgp-multihop 2\",",
            "        \"neighbor {{ bgpPeer2 }} route-map set-med-peer out\"",
            "      ]",
            "    },",
            "    {",
            "      \"frrCmds\": [",
            "        \"conf t\",",
            "        \"route-map To-Ctrlr-1 deny 5\",",
            "        \"match ip address prefix-list default\",",
            "        \"route-map To-Ctrlr-2 deny 5\",",
            "        \"match ip address prefix-list default\",",
            "        \"route-map To-Ctrlr-3 deny 5\",",
            "        \"match ip address prefix-list default\",",
            "        \"route-map To-Ctrlr-4 deny 5\",",
            "        \"match ip address prefix-list default\"",
            "      ]",
            "    },",
            "    {",
            "      \"frrCmds\": [",
            "        \"route-map From-Ctrlr-1 deny 6\",",
            "        \"match community HA_COMMUNITY\",",
            "        \"route-map From-Ctrlr-2 deny 6\",",
            "        \"match community HA_COMMUNITY\",",
            "        \"route-map From-Ctrlr-3 deny 6\",",
            "        \"match community HA_COMMUNITY\",",
            "        \"route-map To-Ctrlr-3 permit 10\",",
            "        \"set community 47474:47474 additive\",",
            "        \"route-map To-Ctrlr-2 permit 10\",",
            "        \"set community 47474:47474 additive\",",
            "        \"route-map To-Ctrlr-1 permit 10\",",
            "        \"set community 47474:47474 additive\",",
            "        \"route-map To-Ctrlr-4 permit 10\",",
            "        \"set community 47474:47474 additive\"",
            "      ]",
            "    },",
            "    {",
            "      \"frrCmds\": [",
            "        \"conf t\",",
            "        \"router bgp {{ bgpAsn }}\",",
            "        \"neighbor {{ bgpPeer1 }} default-originate\",",
            "        \"neighbor {{ bgpPeer2 }} default-originate\"",
            "      ]",
            "    }",
            "  ]",
            "}",
            "FRREOF",
            "chmod 644 /infroot/workdir/frrcmds-user.json",
            "chown root:root /infroot/workdir/frrcmds-user.json",
            "echo 'FRR configuration written successfully.'"
          ]
        }
      },
      {
        action = "aws:runShellScript"
        name   = "configureGRETunnel"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "set -e",
            "echo 'Configuring GRE tunnel...'",
            "infhostd config-gre -inside-ip {{ insideIp }} -inside-mask {{ insideMask }} -intfname {{ intfName }} -local-ip {{ localIp }} -remote-ip {{ remoteIp }} -mtu {{ mtu }} -phy-intfname {{ phyIntfname }}",
            "echo 'Restarting infhost service...'",
            "service infhost restart",
            "echo 'Restarting infhost container...'",
            "infhostd restart-container",
            "echo 'GRE tunnel configured successfully.'"
          ]
        }
      },
      {
        action = "aws:runShellScript"
        name   = "verifyBgpConfig"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "echo 'Waiting for container to fully start...'",
            "MAX_ATTEMPTS=12",
            "ATTEMPT=0",
            "while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do",
            "  RUNNING=$(docker inspect -f '{{.State.Running}}' infiot_spoke 2>/dev/null || echo 'false')",
            "  [ \"$RUNNING\" = \"true\" ] && break",
            "  ATTEMPT=$((ATTEMPT + 1))",
            "  echo \"Waiting for container... attempt $ATTEMPT/$MAX_ATTEMPTS\"",
            "  sleep 10",
            "done",
            "echo 'Container is running. Waiting 30s for FRR to initialize...'",
            "sleep 30",
            "echo 'Checking if BGP neighbors are configured...'",
            "BGP_CHECK=$(docker exec infiot_spoke vtysh -c 'show bgp summary' 2>/dev/null | grep -c '{{ bgpPeer1 }}' || true)",
            "if [ \"$BGP_CHECK\" -eq 0 ]; then",
            "  echo 'BGP neighbors not found after first restart. Retrying container restart...'",
            "  infhostd restart-container",
            "  echo 'Waiting 60s for container and FRR to reinitialize...'",
            "  sleep 60",
            "  BGP_CHECK=$(docker exec infiot_spoke vtysh -c 'show bgp summary' 2>/dev/null | grep -c '{{ bgpPeer1 }}' || true)",
            "  if [ \"$BGP_CHECK\" -eq 0 ]; then",
            "    echo 'WARNING: BGP neighbors still not configured after retry. Manual intervention may be needed.'",
            "    exit 0",
            "  fi",
            "fi",
            "echo 'BGP configuration verified:'",
            "docker exec infiot_spoke vtysh -c 'show bgp summary'"
          ]
        }
      }
    ]
  })

  tags = {
    Name = "${var.environment}-netskope-gre-config"
  }
}

#
# GRE Config: Poll for SSM readiness, send command, poll for completion (one per gateway)
#
resource "null_resource" "gre_config" {
  for_each   = var.gre_configs
  depends_on = [aws_ssm_document.gre_config]

  triggers = {
    instance_id  = each.value.instance_id
    inside_ip    = each.value.inside_ip
    inside_mask  = each.value.inside_mask
    local_ip     = each.value.local_ip
    remote_ip    = each.value.remote_ip
    intf_name    = each.value.intf_name
    mtu          = each.value.mtu
    phy_intfname = each.value.phy_intfname
    bgp_asn      = var.bgp_asn
    tgw_asn      = var.tgw_asn
    bgp_peer1    = each.value.bgp_peers.peer1
    bgp_peer2    = each.value.bgp_peers.peer2
    bgp_metric   = each.value.bgp_metric
  }

  provisioner "local-exec" {
    command = <<-EOT
      REGION="${var.region}"
      INSTANCE_ID="${each.value.instance_id}"

      # Poll for SSM readiness (up to 5 minutes, 10s intervals)
      MAX_ATTEMPTS=30
      ATTEMPT=0
      STATUS="None"
      while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        STATUS=$(aws ssm describe-instance-information \
          --region $REGION \
          --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
          --query "InstanceInformationList[0].PingStatus" \
          --output text 2>/dev/null || echo "None")
        [ "$STATUS" = "Online" ] && break
        ATTEMPT=$((ATTEMPT + 1))
        sleep 10
      done
      [ "$STATUS" != "Online" ] && echo "SSM agent not ready on instance $INSTANCE_ID (gateway ${each.key})" && exit 1

      # Send SSM command
      COMMAND_ID=$(aws ssm send-command \
        --region $REGION \
        --instance-ids $INSTANCE_ID \
        --document-name ${aws_ssm_document.gre_config.name} \
        --parameters '${jsonencode({
          insideIp    = [each.value.inside_ip]
          insideMask  = [each.value.inside_mask]
          localIp     = [each.value.local_ip]
          remoteIp    = [each.value.remote_ip]
          intfName    = [each.value.intf_name]
          mtu         = [each.value.mtu]
          phyIntfname = [each.value.phy_intfname]
          bgpAsn      = [var.bgp_asn]
          bgpPeer1    = [each.value.bgp_peers.peer1]
          bgpPeer2    = [each.value.bgp_peers.peer2]
          bgpMetric   = [each.value.bgp_metric]
          tgwAsn      = [var.tgw_asn]
        })}' \
        --comment "Configure GRE tunnel on gateway ${each.key}" \
        --query "Command.CommandId" \
        --output text)

      # Wait for command completion
      while true; do
        CMD_STATUS=$(aws ssm get-command-invocation \
          --region $REGION \
          --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
          --query Status --output text 2>/dev/null || echo "InProgress")
        case "$CMD_STATUS" in
          Success) echo "GRE config for gateway ${each.key} completed successfully"; break ;;
          Failed|Cancelled|TimedOut) echo "GRE config for gateway ${each.key} failed with status: $CMD_STATUS"; exit 1 ;;
          *) sleep 5 ;;
        esac
      done
    EOT
  }
}
