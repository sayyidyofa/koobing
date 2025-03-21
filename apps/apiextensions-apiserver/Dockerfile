FROM docker.io/library/debian:stable-slim AS build
USER root
WORKDIR /app
RUN apt update && apt install -y curl
RUN curl -Ls https://dl.k8s.io/v1.32.3/bin/linux/amd64/apiextensions-apiserver --output apiextensions-apiserver && chmod +x apiextensions-apiserver

FROM docker.io/library/debian:stable-slim
WORKDIR /app
COPY --from=build /app/apiextensions-apiserver apiextensions-apiserver
ENV PATH=$PATH:/app
ENTRYPOINT [ "/bin/bash", "-l", "-c" ]
# KUBERNETES_SERVICE_HOST=kube1 KUBERNETES_SERVICE_PORT=6443 apiextensions-apiserver --etcd-servers http://kube3:2379 --kubeconfig /etc/kubernetes/kubeconfig --authentication-kubeconfig /etc/kubernetes/kubeconfig --authorization-kubeconfig /etc/kubernetes/kubeconfig