#!/bin/bash

# 1. Создаем необходимые директории
mkdir -p roles/system_init/tasks roles/system_init/handlers roles/infra_core/tasks roles/infra_core/templates example_whoami

# 2. Роль инициализации системы (порты, пользователи, лимиты сна, авторебут)
cat << 'EOF' > roles/system_init/tasks/main.yaml
---
- name: Generate random passwords
  ansible.builtin.set_fact:
    root_password: "{{ lookup('password', '/dev/null length=20 chars=ascii_letters,digits') }}"
    main_password: "{{ lookup('password', '/dev/null length=20 chars=ascii_letters,digits') }}"
    sudo_password: "{{ lookup('password', '/dev/null length=20 chars=ascii_letters,digits') }}"

- name: Create docker group
  ansible.builtin.group:
    name: docker
    state: present

- name: Create main user
  ansible.builtin.user:
    name: main
    password: "{{ main_password | password_hash('sha512') }}"
    groups: sudo,docker
    append: true
    shell: /bin/bash

- name: Set root password
  ansible.builtin.user:
    name: root
    password: "{{ root_password | password_hash('sha512') }}"

- name: Disable sleep and hibernation (Crucial for Home Server)
  ansible.builtin.systemd:
    name: "{{ item }}"
    masked: true
  loop:
    - sleep.target
    - suspend.target
    - hibernate.target
    - hybrid-sleep.target

- name: Ensure /mnt/storage exists
  ansible.builtin.file:
    path: /mnt/storage
    state: directory
    mode: '0755'

- name: Schedule daily reboot at 04:00
  ansible.builtin.cron:
    name: "Daily auto-reboot"
    minute: "0"
    hour: "4"
    job: "/sbin/reboot"

- name: Configure SSH port and disable root login
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
  loop:
    - { regexp: '^#?Port', line: 'Port 2222' }
    - { regexp: '^#?PermitRootLogin', line: 'PermitRootLogin no' }
    - { regexp: '^#?PasswordAuthentication', line: 'PasswordAuthentication no' }
  notify: restart ssh
EOF

cat << 'EOF' > roles/system_init/handlers/main.yaml
---
- name: restart ssh
  ansible.builtin.service:
    name: sshd
    state: restarted
EOF

# 3. Настройка ядра инфраструктуры (Сеть, Контейнеры, Монтирование docker.sock в ro)
cat << 'EOF' > roles/infra_core/tasks/main.yaml
---
- name: Ensure secure-network exists
  community.docker.docker_network:
    name: secure-network
    state: present

- name: Ensure Traefik config directory exists
  ansible.builtin.file:
    path: /opt/infra/traefik/config
    state: directory
    mode: '0755'

- name: Template Traefik configuration
  ansible.builtin.template:
    src: traefik.yaml.j2
    dest: /opt/infra/traefik/config/traefik.yaml

- name: Deploy Core Infrastructure
  community.docker.docker_compose_v2:
    project_name: infra_core
    definition:
      services:
        traefik:
          image: traefik:v3.0
          ports:
            - "80:80"
            - "443:443"
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - /opt/infra/traefik/config/traefik.yaml:/etc/traefik/traefik.yaml:ro
            - /opt/infra/traefik/letsencrypt:/letsencrypt
          networks:
            - secure-network
          labels:
            - "traefik.http.middlewares.crowdsec-waf.plugin.bouncer.enabled=true"
        crowdsec:
          image: crowdsecurity/crowdsec:latest
          environment:
            COLLECTIONS: "crowdsecurity/traefik"
          volumes:
            - /var/log:/var/log:ro
          networks:
            - secure-network
        oxker:
          image: mrnugget/oxker
          tty: true
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
          networks:
            - secure-network
      networks:
        secure-network:
          external: true
EOF

# 4. Шаблон конфигурации Traefik с HTTP Challenge (без DNS API провайдеров)
cat << 'EOF' > roles/infra_core/templates/traefik.yaml.j2
experimental:
  plugins:
    bouncer:
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
        - crowdsec-waf@docker
      tls:
        certResolver: homeResolver

certificatesResolvers:
  homeResolver:
    acme:
      email: "{{ acme_email | default('admin@yourdomain.com') }}"
      storage: "/letsencrypt/acme.json"
      httpChallenge:
        entryPoint: web

providers:
  docker:
    exposedByDefault: false
    network: secure-network
EOF

# 5. Обновленный bootstrap.yaml (ориентирован строго на homelab)
cat << 'EOF' > bootstrap.yaml
---
- name: Homelab Bootstrap (Static IP Setup)
  hosts: homelab
  become: true
  vars_files:
    - vars/hardening.yaml

  tasks:
    - name: Install base packages
      ansible.builtin.include_role:
        name: base_packages

    - name: Setup firewalld
      ansible.builtin.include_role:
        name: firewall

    - name: System Initialization and Hardening
      ansible.builtin.include_role:
        name: system_init

    - name: Setup Core Infrastructure
      ansible.builtin.include_role:
        name: infra_core

    - name: Display Generated Passwords
      ansible.builtin.debug:
        msg: |
          =============================================
          SYSTEM PASSWORDS GENERATED FOR HOME SERVER
          =============================================
          User: root | Pass: {{ hostvars[inventory_hostname]['root_password'] }}
          User: main | Pass: {{ hostvars[inventory_hostname]['main_password'] }}
          User: sudo | Pass: {{ hostvars[inventory_hostname]['sudo_password'] }}
          =============================================

- name: Homelab specific actions
  hosts: homelab
  become: true
  roles:
    - homelab
EOF

# 6. Пример docker-compose.yaml для микросервисов (Авто-WAF + HTTP SSL)
cat << 'EOF' > example_whoami/docker-compose.yaml
services:
  whoami:
    image: traefik/whoami
    networks:
      - secure-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.whoami.rule=Host(`whoami.yourdomain.com`)"
      - "traefik.http.routers.whoami.entrypoints=websecure"
      - "traefik.http.routers.whoami.tls=true"
      - "traefik.http.routers.whoami.tls.certresolver=homeResolver"

networks:
  secure-network:
    external: true
EOF
