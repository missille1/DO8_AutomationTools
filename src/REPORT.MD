
```ruby
Vagrant.configure("2") do |config|
  BOX = "ubuntu-22.04"   # jammy64
  CPU = 8
  RAM = 1500

  # приватная сеть (host-only)
  MANAGER_IP = "192.168.56.10"
  NODE01_IP  = "192.168.56.11"
  NODE02_IP  = "192.168.56.12"

  # manager
  config.vm.define "manager" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "manager"
    vm.vm.network "private_network", ip: MANAGER_IP
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU
      vb.memory = RAM
    end
  end

  # node01 — сюда будем деплоить микросервисы; пробрасываем порты для доступа с хоста
  config.vm.define "node01" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "node01"
    vm.vm.network "private_network", ip: NODE01_IP
    # проброс портов для твоего compose (session:8081, gateway:8087)
    vm.vm.network "forwarded_port", guest: 8081, host: 8081, host_ip: "127.0.0.1", auto_correct: true
    vm.vm.network "forwarded_port", guest: 8087, host: 8087, host_ip: "127.0.0.1", auto_correct: true
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU
      vb.memory = 5120
    end
  end

  # node02 — сюда позже назначим роли apache и postgres
  config.vm.define "node02" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "node02"
    vm.vm.network "private_network", ip: NODE02_IP
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU
      vb.memory = RAM
    end
  end
end
```


Прокидывания ключа на node01 и node02 c manager

```bash
# на manager
ssh-keygen -t ed25519 -C "manager"
```

```bash
# на manager
ssh-copy-id -i ~/.ssh/ vagrant@192.168.56.11
ssh-copy-id -i ~/.ssh/ vagrant@192.168.56.12
```

```bash
ssh vagrant@192.168.56.11
ssh vagrant@192.168.56.12
```

```bash
# на ХОСТЕ
vagrant upload ../services/ /home/vagrant/services manager
```

```bash
# на manager
sudo apt update
sudo apt install -y ansible

mkdir -p ~/ansible
vim ~/ansible/inventory.yml
```

```yml
nodes:
  hosts:
    node01:
      ansible_host: 192.168.56.11
    node02:
      ansible_host: 192.168.56.12
  vars:
    ansible_user: vagrant
```

```bash
ansible -i ./ansible/inventory.yml all -m ping
```


```yml
---
- name: Prepare node01 and deploy microservices
  hosts: node01
  become: true
  vars:
    # На manager
    app_src_dir: /home/vagrant/services
    # Куда копируем на node01
    app_dest_dir: /home/vagrant/services
    compose_file: "{{ app_dest_dir }}/docker-compose.yml"
    docker_gpg_url: "https://download.docker.com/linux/ubuntu/gpg"
    docker_apt_repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable"

  tasks:
    - name: Docker | Update repositories cache
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600 

    - name: Docker | Download Docker GPG key
      ansible.builtin.get_url:
        url: "{{ docker_gpg_url }}"
        dest: /etc/apt/keyrings/docker.asc
        mode: "0644"

    - name: Docker | Add Docker repository
      ansible.builtin.apt_repository:
        repo: "{{ docker_apt_repo }}"
        state: present # убедиться что репозиторий есть в системе
        filename: docker.list

    - name: Docker | Update repositories cache
      ansible.builtin.apt:
        update_cache: true

    - name: Docker | Install Docker packages
      ansible.builtin.apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-buildx-plugin
          - docker-compose-plugin
        state: present
        update_cache: true

    - name: Docker | enable and start service
      ansible.builtin.service:
        name: docker
        enabled: true
        state: started

    - name: Docker | add vagrant to docker group
      ansible.builtin.user:
        name: vagrant
        groups: docker
        append: true

    - name: node01 | ensure destination directory exists on node01
      ansible.builtin.file:
        path: "{{ app_dest_dir }}"
        state: directory
        owner: vagrant
        group: vagrant
        mode: "0755"

    - name: node01 | copy sources & compose from manager to node01
      ansible.builtin.copy:
        src: "{{ app_src_dir }}/docker-compose.yml"
        dest: "{{ app_dest_dir }}/docker-compose.yml"
        owner: vagrant
        group: vagrant
        mode: "0644"
        directory_mode: "0755"

    - name: Docker | pre-pull base images
      ansible.builtin.command:
        cmd: "docker compose -f {{ compose_file }} pull"
        chdir: "{{ app_dest_dir }}"
      register: compose_pull # сохраняем результат в переменную
      changed_when: "'Downloaded' in compose_pull.stdout or 'Pull complete' in compose_pull.stdout"

    - name: node01 | start containers
      ansible.builtin.command:
        cmd: "docker compose -f {{ compose_file }} up -d"
        chdir: "{{ app_dest_dir }}"
      register: compose_up

    - name: Wait | give containers time to warm up
      ansible.builtin.pause:
        seconds: 90

    - name: Info | show running containers
      ansible.builtin.command:
        argv:
          - docker
          - ps
          - --format
          - "{{'{{'}}.Names{{'}}'}}\t{{'{{'}}.Status{{'}}'}}\t{{'{{'}}.Ports{{'}}'}}"
      changed_when: false
      register: dps

    - name: Info | containers table
      ansible.builtin.debug:
        var: dps.stdout_lines
```

```yml
services:
  postgres:
    image: missille1/postgres:15.1-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: users_db
    networks:
      - booking_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  rabbitmq:
    image: rabbitmq:3-management-alpine
    networks:
      - booking_network

  session:
    image: missille1/services-session:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: users_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network
    ports:
      - "8081:8081"

  hotel:
    image: missille1/services-hotel:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: hotels_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  payment:
    image: missille1/services-payment:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: payments_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  loyalty:
    image: missille1/services-loyalty:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: balances_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  report:
    image: missille1/services-report:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: statistics_db
      RABBIT_MQ_HOST: rabbitmq
      RABBIT_MQ_PORT: 5672
      RABBIT_MQ_USER: guest
      RABBIT_MQ_PASSWORD: guest
      RABBIT_MQ_QUEUE_NAME: messagequeue
      RABBIT_MQ_EXCHANGE: messagequeue-exchange
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  booking:
    image: missille1/services-booking:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: reservations_db
      RABBIT_MQ_HOST: rabbitmq
      RABBIT_MQ_PORT: 5672
      RABBIT_MQ_USER: guest
      RABBIT_MQ_PASSWORD: guest
      RABBIT_MQ_QUEUE_NAME: messagequeue
      RABBIT_MQ_EXCHANGE: messagequeue-exchange
      HOTEL_SERVICE_HOST: hotel
      HOTEL_SERVICE_PORT: 8082
      PAYMENT_SERVICE_HOST: payment
      PAYMENT_SERVICE_PORT: 8084
      LOYALTY_SERVICE_HOST: loyalty
      LOYALTY_SERVICE_PORT: 8085
    depends_on:
      - postgres
      - rabbitmq
      - hotel
      - payment
      - loyalty
    networks:
      - booking_network

  gateway:
    image: missille1/services-gateway:v1.1
    networks:
      - booking_network
    depends_on:
      - postgres
      - rabbitmq
      - hotel
      - booking
      - payment
      - loyalty
      - report
      - session
    environment:
      SESSION_SERVICE_HOST: session
      SESSION_SERVICE_PORT: 8081
      HOTEL_SERVICE_HOST: hotel
      HOTEL_SERVICE_PORT: 8082
      BOOKING_SERVICE_HOST: booking
      BOOKING_SERVICE_PORT: 8083
      PAYMENT_SERVICE_HOST: payment
      PAYMENT_SERVICE_PORT: 8084
      LOYALTY_SERVICE_HOST: loyalty
      LOYALTY_SERVICE_PORT: 8085
      REPORT_SERVICE_HOST: report
      REPORT_SERVICE_PORT: 8086
    ports:
      - "8087:8087"
      
networks:
  booking_network:
    driver: bridge
```

```bash
# на manager
ansible-playbook -i ~/ansible/inventory.yml ~/ansible/deploy_node01.yml
```

```bash
# на manager
cd ~/ansible
ansible-galaxy init roles/application
ansible-galaxy init roles/apache
ansible-galaxy init roles/postgres
```

чтобы ansible мог взаимодействовать в бд
```bash
# на manager
sudo ansible-galaxy collection install community.postgresql
```

```bash
printf '%s\n' '[defaults]' 'remote_tmp = /tmp' 'allow_world_readable_tmpfiles = False' > ansible.cfg
```

```bash
# node02
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'pgpass';"
```

```bash
# на хосте
psql "postgresql://postgres:pgpass@192.168.56.12:5432/school21" -c 'TABLE public.students;'
```

```
# на хосте apache
http://192.168.56.12/
```

```bash
ansible-playbook -i ~/ansible/inventory.yml ~/ansible/site.yml
```