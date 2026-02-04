# GRE + TGW Automation Discussion

## Feedback from Team Review

### GRE Configuration Commands

- **Action Required:** Add `infhostd restart-container` along with `service infhost restart` after running the `infhostd gre` command.

### Interface Name Correction

- **Correction:** The `phy_intfname` should be `enp2s1` instead of `ens6`.

### SSM Agent

- **Is SSM Agent pre-installed on the Netskope SASE Gateway AMI?**
  - Need to check with Ops team. Likely **not** installed by default.
- **If not, can it be installed via user data at launch?**
  - Need to validate with Ops/Engineering team whether this is supported.

### Gateway Access

- **What is the default OS user for SSH access?**
  - `infiot`
- **What is the root password / SSH key for the gateway?**
  - Root password is `infiot` (by default). This can be set by the customer from the portal during Gateway creation.

### GRE Configuration Persistence

| Question | Answer |
|----------|--------|
| Does GRE config survive instance reboot? | Yes |
| Does GRE config survive infhostd upgrades? | Yes |
| Is `/infroot/workdir/` persistent storage? | Yes |

### IAM and VPC Endpoints

- **What IAM permissions does the gateway instance need for SSM?**
  - AWS Systems Manager permissions (e.g., `AmazonSSMManagedInstanceCore` managed policy).
- **Are there VPC endpoints available for SSM in the deployment region?**
  - Need to check with Ops team.
