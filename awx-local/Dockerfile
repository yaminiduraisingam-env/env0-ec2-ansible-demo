# awx-local/Dockerfile
# Extends the Semaphore image with Ansible installed.
# semaphoreui/semaphore is Alpine-based so we use apk.
FROM semaphoreui/semaphore:latest
USER root
RUN apk add --no-cache \
    ansible \
    openssh-client \
    py3-pip \
    python3
USER semaphore
