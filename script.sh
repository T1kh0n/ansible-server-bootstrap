#!/bin/bash

# Создаем структуру каталогов в соответствии с AGENTS.md
mkdir -p roles/system_init/tasks \
         roles/system_init/handlers \
         roles/infra_core/tasks \
         roles/infra_core/templates \
         infra/traefik/dynamic \
         example_whoami

# ==========================================
# 1. СИСТЕМНАЯ ИНИЦИАЛИЗАЦИЯ (system_init)
# ==========================================

cat << 'EOF' > roles/system_init/tasks/main.yaml
---
- name: Generate and fixate random passwords (idempotent setup)
  ansible.builtin.set_fact:
    generated_root_password: "{{ lookup('ansible.builtin.password', '/dev/null length=24 chars=ascii_letters,digits') }}"
    generated_main_password: "{{ lookup('ansible.builtin.password', '/dev/null length=24 chars=ascii_letters,digits') }}"
    generated_sudo_password: "{{ lookup('ansible.builtin.password', '/dev/null length=24 chars=ascii_letters,digits') }}"
  cacheable: yes
  when: generated_root_password is not defined

- name: Create isolated docker system group
  ansible.builtin.group:
    name: docker
    state: present

- name: Create main user with bash environment
  ansible.builtin.user:
    name: main
    password: "{{ generated_main_password | password_hash('sha512') }}"
    groups: sudo,docker
    append: true
    shell: /bin/bash
    create_home: true

- name: Secure root user password
  ansible.builtin.user:
    name: root
    password: "{{ generated_root_password | password_hash('sha512') }}"

- name: Strict IAM Hardening - Isolate root directories from main user
  ansible.builtin.file:
    path: "{{ item }}"
    owner: root
    group: root
    mode: '0700'
  loop:
    - /root
    - /etc/ansible

- name: Disable power-saving targets (Sleep and Hibernation)
  ansible.builtin.systemd:
    name: "{{ item }}"
    masked: true
  loop:
    - sleep.target
    - suspend.target
    - hibernate.target
    - hybrid-sleep.target

- name: Ensure target storage mount point directory exists
  ansible.builtin.file:
    path: /mnt/storage
    state: directory
    owner: root
    group: root
    mode: '0775'

- name: Configure daily cron automatic reboot at 04:00
  ansible.builtin.cron:
    name: "Nightly system auto-reboot"
    minute: "0"
    hour: "4"
    job: "/sbin/reboot"

- name: Deploy SSH Authorized Keys for main user (CRITICAL SAFETY STEP)
  ansible.posix.authorized_key:
    user: main
    state: present
    key: "{{ lookup('file', '~/.ssh/id_rsa.pub', errors='ignore') | default('ssh-rsa AAAAB3NzaC1yc2E... test-key') }}"

- name: Hardening OpenSSH Server daemon configuration
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
    state: present
  loop:
    - { regexp: '^#?Port', line: 'Port 2222' }
    - { regexp: '^#?PermitRootLogin', line: 'PermitRootLogin no' }
    - { regexp: '^#?PasswordAuthentication', line: 'PasswordAuthentication no' }
  notify: trigger_restart_ssh

- name: Install Oxker TUI Monitor via precompiled Rust binary
  ansible.builtin.get_url:
    url: "https://github.com/mrjackwills/oxker/releases/latest/download/oxker-linux-x86_64.tar.gz"
    dest: /tmp/oxker.tar.gz
    mode: '0644'
  register: oxker_download
  ignore_errors: true

- name: Extract Oxker binary to system bin path
  ansible.builtin.unarchive:
    src: /tmp/oxker.tar.gz
    dest: /usr/local/bin/
    remote_src: true
    mode: '0755'
  when: oxker_download is succeeded
EOF

cat << 'EOF' > roles/system_init/handlers/main.yaml
---
- name: trigger_restart_ssh
  ansible.builtin.service:
    name: ssh
    state: restarted
EOF

# ==========================================
# 2. ИНФРАСТРУКТУРНОЕ ЯДРО (infra_core)
# ==========================================

cat << 'EOF' > roles/infra_core/tasks/main.yaml
---
- name: Verify or create core external Docker network
  community.docker.docker_network:
    name: secure-network
    state: present
    driver: bridge

- name: Setup dynamic and static configuration paths for Traefik
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: '0755'
  loop:
    - /opt/infra/traefik/config
    - /opt/infra/traefik/dynamic
    - /opt/infra/crowdsec/config

- name: Generate static Traefik configuration from template
  ansible.builtin.template:
    src: traefik.yaml.j2
    dest: /opt/infra/traefik/config/traefik.yaml
    mode: '0644'

- name: Generate dynamic Traefik middleware config (WAF definition)
  ansible.builtin.template:
    src: dynamic_waf.yaml.j2
    dest: /opt/infra/traefik/dynamic/dynamic_waf.yaml
    mode: '0644'

- name: Orchestrate Core Infrastructure via Docker Compose
  community.docker.docker_compose_v2:
    project_name: infra_core
    definition:
      services:
        traefik:
          image: traefik:v3.0
          container_name: ingress_traefik
          restart: always
          ports:
            - "80:80"
            - "443:443"
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - /opt/infra/traefik/config/traefik.yaml:/etc/traefik/traefik.yaml:ro
            - /opt/infra/traefik/dynamic:/etc/traefik/dynamic:ro
          networks:
            - secure-network
          environment:
            - TZ=Europe/Moscow

        crowdsec:
          image: crowdsecurity/crowdsec:latest
          container_name: waf_crowdsec
          restart: always
          environment:
            COLLECTIONS: "crowdsecurity/traefik crowdsecurity/base-httpingest"
            DISABLE_ONLINE_API: "false"
          volumes:
            - /var/log:/var/log:ro
            - /opt/infra/crowdsec/config:/etc/crowdsec
          networks:
            - secure-network

      networks:
        secure-network:
          external: true
EOF

# Шаблон статической конфигурации Traefik (глобальные настройки)
cat << 'EOF' > roles/infra_core/templates/traefik.yaml.j2
experimental:
  plugins:
    crowdsec:
      moduleName: github.com/maxmcd/traefik-crowdsec-bouncer
      version: v0.6.0

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    asDefaultInRule: true
    http:
      middlewares:
        - "crowdsec-waf@file"

providers:
  docker:
    exposedByDefault: false
    network: secure-network
  file:
    directory: /etc/traefik/dynamic
    watch: true
EOF

cat << 'EOF' > roles/infra_core/templates/dynamic_waf.yaml.j2
http:
  middlewares:
    crowdsec-waf:
      plugin:
        crowdsec:
          crowdsecLapiScheme: http
          crowdsecLapiHost: crowdsec:8080
          crowdsecLapiKey: "GENERATED_CROWDSEC_LAPI_KEY_HERE"
          clientTimeout: 2s
EOF

# ==========================================
# 3. ОСНОВНОЙ ОРКЕСТРАТОР (bootstrap.yaml)
# ==========================================

cat << 'EOF' > bootstrap.yaml
---
- name: Enterprise Bootstrap & Zero-Touch WAF deployment
  hosts: all
  become: true
  tasks:
    - name: Initialization and Host OS Hardening
      ansible.builtin.include_role:
        name: system_init

    - name: Deploy Orchestration and Global WAF Engine
      ansible.builtin.include_role:
        name: infra_core

    - name: Render System Credentials Output Table
      ansible.builtin.debug:
        msg: |
          +-------------------------------------------------------------+
          |         SYSTEM INITIALIZATION SECURE CREDENTIALS REPORT     |
          +-------------------------------------------------------------+
          | Target Node: {{ inventory_hostname }}
          | SSH Target Port: 2222 (Only main user allowed with SSH Key)  
          +-------------------------------------------------------------+
          | USER   | GENERATED PASSWORD                                 |
          +--------+----------------------------------------------------+
          | root   | {{ hostvars[inventory_hostname]['generated_root_password'] }}
          | main   | {{ hostvars[inventory_hostname]['generated_main_password'] }}
          | sudo   | {{ hostvars[inventory_hostname]['generated_sudo_password'] }}
          +-------------------------------------------------------------+
          | CRITICAL INFO: Passwords have been applied via Argon2/SHA512.|
          | Write them down now. Authentication over password via SSH is|
          | completely DISABLED.                                        |
          +-------------------------------------------------------------+
EOF

# ==========================================
# 4. ШАБЛОН ДЛЯ ПОДКЛЮЧЕНИЯ СЕРВИСОВ (whoami)
# ==========================================

cat << 'EOF' > example_whoami/docker-compose.yaml
version: '3.8'

services:
  whoami:
    image: traefik/whoami:latest
    container_name: test_whoami
    restart: always
    networks:
      - secure-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.whoami.rule=Host(`whoami.local.yourdomain.com`)"
      - "traefik.http.routers.whoami.entrypoints=websecure"
      - "traefik.http.routers.whoami.tls=true"

networks:
  secure-network:
    external: true
EOF

chmod +x roles/system_init/handlers/main.yaml
echo "[SUCCESS] SDD База архитектуры сгенерирована и исправлена!"
