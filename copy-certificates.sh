USER=root
PRIV_KEY=/home/vagrant/.ssh/id_rsa
CONTROL_PLANE_IPS="10.10.1.3 10.10.1.4"
for host in ${CONTROL_PLANE_IPS}; do
    scp -i $PRIV_KEY /etc/kubernetes/pki/ca.crt "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/ca.key "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/sa.key "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/sa.pub "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/front-proxy-ca.crt "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/front-proxy-ca.key "${USER}"@$host:
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.crt "${USER}"@$host:etcd-ca.crt
    scp -i $PRIV_KEY /etc/kubernetes/pki/etcd/ca.key "${USER}"@$host:etcd-ca.key
done
