#------------------------------------------------------------------------------
#  GRE Config - SSM-based FRR JSON writing + GRE tunnel configuration
#------------------------------------------------------------------------------

# --- GRE config data ---

locals {
  gre_configs = {
    for gw_key, gw in local.gateways : gw_key => {
      instance_id  = aws_instance.gateways[gw_key].id
      inside_ip    = cidrhost(gw.inside_cidr, 1)
      inside_mask  = cidrnetmask(gw.inside_cidr)
      local_ip     = tolist(aws_network_interface.gw_interfaces["${gw_key}-${local.gw_lan_key[gw_key]}"].private_ips)[0]
      remote_ip    = aws_ec2_transit_gateway_connect_peer.gw_peers[gw_key].transit_gateway_address
      intf_name    = "gre1"
      mtu          = tostring(var.netskope_gateway_config.gre_mtu)
      phy_intfname = var.aws_transit_gw.phy_intfname
      tgw_cidr     = var.aws_transit_gw.tgw_cidr
      lan_gateway   = cidrhost(gw.subnets[local.gw_lan_key[gw_key]].subnet_cidr, 1)
      static_routes = join(",", var.netskope_gateway_config.static_routes)
      bgp_peers = {
        peer1 = cidrhost(gw.inside_cidr, 2)
        peer2 = cidrhost(gw.inside_cidr, 3)
      }
      bgp_metric       = gw.bgp_metric
      activation_token = netskopebwan_gateway_activate.gateways[gw_key].token
      tenant_uri       = "https://${local.tenant_url}"
    }
  }
}

# --- SSM Document for FRR config writing + GRE tunnel setup ---

resource "aws_ssm_document" "gre_config" {
  name            = "${replace(var.netskope_gateway_config.gateway_policy, "-", "_")}_netskope_gre_config"
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
      tgwCidr = {
        type        = "String"
        description = "TGW CIDR block for policy routing"
      }
      lanGateway = {
        type        = "String"
        description = "LAN subnet gateway IP"
      }
      staticRoutes = {
        type        = "String"
        description = "Comma-separated list of CIDRs to route via LAN interface"
        default     = ""
      }
      activationToken = {
        type        = "String"
        description = "Gateway activation token"
      }
      tenantUri = {
        type        = "String"
        description = "Netskope tenant URI for activation"
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "activateGateway"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "set -e",
            "echo 'Activating gateway...'",
            "infhostd activate -uri {{ tenantUri }} -token {{ activationToken }} || echo 'Activation failed (gateway may already be activated) — continuing...'",
            "echo 'Waiting 30s for activation to propagate...'",
            "sleep 30"
          ]
        }
      },
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
            "echo 'Adding TGW CIDR route to policy routing table 101...'",
            "# The Netskope agent creates table 101 with a default route via the WAN interface.",
            "# GRE outer packets sourced from the LAN IP must route via the LAN interface to reach the TGW.",
            "ip route replace {{ tgwCidr }} via {{ lanGateway }} dev {{ phyIntfname }} table 101 2>/dev/null || echo 'Table 101 not yet present — route will be added after container restart'",
            "echo 'Restarting infhost service...'",
            "service infhost restart",
            "echo 'Restarting infhost container...'",
            "infhostd restart-container",
            "echo 'Waiting 10s for agent to repopulate routing tables...'",
            "sleep 10",
            "echo 'Re-adding TGW CIDR route to table 101 (in case agent overwrote it)...'",
            "ip route replace {{ tgwCidr }} via {{ lanGateway }} dev {{ phyIntfname }} table 101 2>/dev/null || true",
            "echo 'Installing static routes via LAN interface...'",
            "IFS=',' read -ra CIDRS <<< '{{ staticRoutes }}'",
            "for CIDR in \"$${CIDRS[@]}\"; do",
            "  [ -z \"$CIDR\" ] && continue",
            "  ip route replace $CIDR via {{ lanGateway }} dev {{ phyIntfname }} 2>/dev/null || true",
            "  ip route replace $CIDR via {{ lanGateway }} dev {{ phyIntfname }} table 101 2>/dev/null || true",
            "  echo \"  Added route: $CIDR via {{ lanGateway }} dev {{ phyIntfname }}\"",
            "done",
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
    Name = "${var.netskope_gateway_config.gateway_policy}-netskope-gre-config"
  }
}

# --- GRE Config: Poll for SSM readiness, send command, poll for completion ---

resource "null_resource" "gre_config" {
  for_each   = local.gre_configs
  depends_on = [aws_ssm_document.gre_config]

  triggers = {
    instance_id      = each.value.instance_id
    inside_ip        = each.value.inside_ip
    inside_mask      = each.value.inside_mask
    local_ip         = each.value.local_ip
    remote_ip        = each.value.remote_ip
    intf_name        = each.value.intf_name
    mtu              = each.value.mtu
    phy_intfname     = each.value.phy_intfname
    tgw_cidr         = each.value.tgw_cidr
    lan_gateway      = each.value.lan_gateway
    static_routes    = each.value.static_routes
    bgp_asn          = var.netskope_tenant.tenant_bgp_asn
    tgw_asn          = var.aws_transit_gw.tgw_asn
    bgp_peer1        = each.value.bgp_peers.peer1
    bgp_peer2        = each.value.bgp_peers.peer2
    bgp_metric       = each.value.bgp_metric
    activation_token = each.value.activation_token
    tenant_uri       = each.value.tenant_uri
  }

  provisioner "local-exec" {
    command = <<-EOT
      ${path.module}/scripts/ssm_send_command.sh \
        "${var.aws_network_config.region}" \
        "${each.value.instance_id}" \
        "${aws_ssm_document.gre_config.name}" \
        '${jsonencode({
    insideIp        = [each.value.inside_ip]
    insideMask      = [each.value.inside_mask]
    localIp         = [each.value.local_ip]
    remoteIp        = [each.value.remote_ip]
    intfName        = [each.value.intf_name]
    mtu             = [each.value.mtu]
    phyIntfname     = [each.value.phy_intfname]
    bgpAsn          = [var.netskope_tenant.tenant_bgp_asn]
    bgpPeer1        = [each.value.bgp_peers.peer1]
    bgpPeer2        = [each.value.bgp_peers.peer2]
    bgpMetric       = [each.value.bgp_metric]
    tgwAsn          = [var.aws_transit_gw.tgw_asn]
    tgwCidr         = [each.value.tgw_cidr]
    lanGateway      = [each.value.lan_gateway]
    staticRoutes    = [each.value.static_routes]
    activationToken = [each.value.activation_token]
    tenantUri       = [each.value.tenant_uri]
})}' \
        "Configure GRE tunnel on gateway ${each.key}"
    EOT
}
}
