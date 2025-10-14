
Прокидывания ключа на node1 c manager

```bash
# на manager
ssh-keygen -t ed25519 -C "manager-to-node01" -N "" -f ~/.ssh/id_ed25519
```

```bash
# на ХОСТЕ
mkdir -p /tmp/ansible01
vagrant ssh manager -c "cat ~/.ssh/id_ed25519.pub" > /tmp/ansible01/manager_id_ed25519.pub
```

```bash
# на ХОСТЕ
vagrant upload /tmp/ansible01/manager_id_ed25519.pub /home/vagrant/manager_id_ed25519.pub node01

vagrant ssh node01 -c "mkdir -p ~vagrant/.ssh && chmod 700 ~vagrant/.ssh \
  && cat /home/vagrant/manager_id_ed25519.pub >> ~vagrant/.ssh/authorized_keys \
  && chmod 600 ~vagrant/.ssh/authorized_keys \
  && rm /home/vagrant/manager_id_ed25519.pub"
```

```bash
vagrant ssh manager
ssh vagrant@192.168.56.11
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
cat > ~/ansible/inventory.ini <<'EOF'
[application]
node01 ansible_host=192.168.56.11

[apache]
node02 ansible_host=192.168.56.12

[postgres]
node02 ansible_host=192.168.56.12

[all:vars]
ansible_user=vagrant
ansible_ssh_private_key_file=~/.ssh/id_ed25519
EOF
```

