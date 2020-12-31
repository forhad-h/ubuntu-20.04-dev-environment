# Kali Linux Top10
FROM kalilinux/kali-rolling

# Fix of apt update error
RUN echo "deb http://kali.download/kali kali-rolling main contrib non-free" > /etc/apt/sources.list

# do APT update
RUN apt-get -y update && apt-get -y dist-upgrade && apt-get -y autoremove && apt-get clean
# install Kali Linux "Top 10" metapackage and a couple "nice to have" tools
RUN apt-get -y install wpscan

VOLUME /root /var/lib/postgresql
# default LPORT for reverse shell
EXPOSE 4444

WORKDIR /root
CMD ["/bin/bash"]

