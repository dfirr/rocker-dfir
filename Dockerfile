# Base image is Ubuntu-based
FROM rocker/tidyverse:latest

# Install Japanese fonts and required tools
RUN apt update && \
    apt install --no-install-recommends -y \
        ca-certificates \
        bzip2 unzip wget \
        libpng-dev libmagick++-dev \
        python3 python3-pip python3-venv \
        git gh curl jq \
        fonts-ipafont \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Install additional R packages
ARG R_PACKAGES=""
ARG GH_PACKAGES=""
RUN if [ -n "${R_PACKAGES}" ]; then \
    install2.r --error --skipinstalled --deps TRUE ${R_PACKAGES}; \
    fi
RUN if [ -n "${GH_PACKAGES}" ]; then \
    installGithub.r --error ${GH_PACKAGES}; \
    fi

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
