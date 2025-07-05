# ScriptN8N

comando para eliminar docker

sudo apt-get purge -y $(dpkg -l | awk '/docker|containerd|runc/ {print $2}') && sudo apt-get autoremove -y --purge && sudo rm -rf /var/lib/docker /var/lib/containerd
