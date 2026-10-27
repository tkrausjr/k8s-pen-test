FROM alpine:3.19

# Install dependencies: bash, curl, python3, and ncurses (for tput)
RUN apk update --no-check-certificate 
RUN apk add --no-check-certificate --no-cache \
    bash \
    curl \
    python3 \
    ncurses

# Install kubectl
RUN curl -LOk "https://dl.k8s.io/release/$(curl -L -s -k https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Set working directory and copy the script
WORKDIR /scripts
COPY waf-demo.sh .
RUN chmod +x waf-demo.sh

# Keep the container running or drop into a bash shell
CMD ["/bin/bash"]