# Base image is Ubuntu-based
FROM rocker/tidyverse:latest

# Install Japanese fonts and required tools
RUN apt update && \
    apt install --no-install-recommends -y \
        acl \
        ca-certificates \
        bzip2 unzip wget \
        libpng-dev libmagick++-dev \
        python3 python3-pip python3-venv \
        openssh-client \
        git gh curl jq \
        fonts-ipafont \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Corporate CA trust (build time)
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_DIR=/etc/ssl/certs
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
COPY corp_ca/ /usr/local/share/ca-certificates/corp/
RUN if find /usr/local/share/ca-certificates/corp -type f -name '*.crt' -print -quit | grep -q .; then \
      update-ca-certificates; \
    fi

# Install additional R packages
ARG R_PACKAGES_FILE="r_packages.txt"
ARG GH_PACKAGES_FILE="gh_packages.txt"
COPY ${R_PACKAGES_FILE} /tmp/r_packages.txt
COPY ${GH_PACKAGES_FILE} /tmp/gh_packages.txt
RUN gh_list="$(awk 'NF && $1 !~ /^#/' /tmp/gh_packages.txt | tr '\n' ' ')" \
 && if [ -n "${gh_list}" ]; then installGithub.r ${gh_list}; fi
RUN r_list="$(awk 'NF && $1 !~ /^#/' /tmp/r_packages.txt | tr '\n' ' ')" \
 && if [ -n "${r_list}" ]; then install2.r --error --skipinstalled --deps TRUE ${r_list}; fi

# Copy fonts to /etc/rstudio/fonts
RUN cp /usr/share/fonts/opentype/ipafont-mincho/ipam.ttf /etc/rstudio/fonts/ipam.ttf && \
    cp /usr/share/fonts/opentype/ipafont-gothic/ipag.ttf /etc/rstudio/fonts/ipag.ttf

RUN wget "https://github.com/yuru7/HackGen/releases/download/v2.10.0/HackGen_v2.10.0.zip"
RUN unzip ./HackGen_v2.10.0.zip
RUN mv ./HackGen_v2.10.0/* /etc/rstudio/fonts

# Set up Python for reticulate
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN mkdir -p /opt/uv/python && chmod -R a+rX /opt/uv
ENV RETICULATE_VENV=/opt/r
RUN uv python install 3.12 \
 && uv venv "${RETICULATE_VENV}" --python 3.12 \
 && "${RETICULATE_VENV}/bin/python" -V
RUN chown -R rstudio:rstudio "${RETICULATE_VENV}" \
 && chmod -R a+rX "${RETICULATE_VENV}"

# Set reticulate Python path
ENV RETICULATE_PYTHON="${RETICULATE_VENV}/bin/python"

# Install Python packages for reticulate
COPY pip_requirements.txt /tmp/pip_requirements.txt
RUN uv pip install --python "${RETICULATE_VENV}/bin/python" -r /tmp/pip_requirements.txt \
 && rm -f /tmp/pip_requirements.txt

# Provision multi-user accounts and homes at container startup
COPY container/init/30-provision-users.sh /etc/cont-init.d/30-provision-users
RUN chmod +x /etc/cont-init.d/30-provision-users \
 && mkdir -p /etc/rstudio/skel-config /etc/rstudio/skel-msticpy /srv/rstudio-home /srv/cases
