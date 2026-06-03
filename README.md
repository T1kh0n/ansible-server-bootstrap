# ansible-server-bootstrap

An Ansible playbook for bootstrapping secured Debian servers with automated core infrastructure.

## What it does:

1. **System Hardening:** Configures SSH on port 2222, disables root login, enforces key-based access, and generates random credentials for main/root/sudo.
2. **OS Optimization:** Sets up `/mnt/storage`, disables sleep/hibernation, and configures scheduled reboots.
3. **Core Infrastructure:** Deploys Docker, Traefik (Ingress), CrowdSec, and Oxker (TUI monitoring).
4. **Zero-Touch WAF:** Integrates global CrowdSec AppSec middleware at the entrypoint level.
5. **Secure Networking:** Creates a private `secure-network` for all microservices without exposing host ports.
6. **Maintenance:** Enables automatic security updates and Pushover notifications for required reboots.
7. **Base Environment:** Installs standard tools and manages firewalld policies.

## hosts.yaml example

```yaml
all:
  vars:
    pushover_user_key: "exampleusertoken"
  
  children:
    homelab:
      hosts:
        example.com:
          enable_ssh_password: true
      vars:
        pushover_app_token: "rqwrwqeqweqeqe"
    vps:
      hosts:
        example1.com:
      vars:
        pushover_app_token: "examplewewewewe"

```

## Security Note

The playbook includes a debug task at the end of the bootstrap process. After running `ansible-playbook bootstrap.yaml`, it will output the dynamically generated passwords for the system users directly to your terminal. Ensure your console buffer is secure.
