requirements:
- a running etcd server
- kube-apiserver in /usr/local/bin
- kubeconfig in /etc/kubernetes
- jwt keypair in /etc/kubernetes (public.key, private.key)
- tls crt and private key in /etc/kubernetes (with correct SAN)