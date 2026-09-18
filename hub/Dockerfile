FROM python:3.14-slim

# configurable-http-proxy is a Node program; the hub shells out to it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm curl \
 && npm install -g configurable-http-proxy \
 && npm cache clean --force \
 && apt-get purge -y npm && apt-get autoremove -y \
 && apt-get clean \
 && find /var/lib/apt/lists -mindepth 1 -delete

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY jupyterhub_config.py /srv/jupyterhub/jupyterhub_config.py
COPY templates/ /srv/jupyterhub/templates/

WORKDIR /srv/jupyterhub
EXPOSE 8000

CMD ["jupyterhub", "-f", "/srv/jupyterhub/jupyterhub_config.py"]
