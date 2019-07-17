USER=root
PRIV_KEY=/home/vagrant/.ssh/id_rsa
CONTROL_PLANE_IPS="10.10.1.3 10.10.1.4"
for host in ${CONTROL_PLANE_IPS}; do
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.crt "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.key "${USER}"@$host:
done
