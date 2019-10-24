FROM ubuntu
MAINTAINER Sam Bäumer <sam@schplorg.de>
RUN apt-get update
RUN apt-get install -y wget
RUN apt-get install -y perl libio-socket-ssl-perl libnet-libidn-perl libnet-ssleay-perl perl-openssl-defaults
RUN wget http://downloads.slimdevices.com/nightly/7.9/sc/4b35964a8b3d464817b37c15244e28e920307814/logitechmediaserver_7.9.2~1571644358_all.deb
RUN dpkg -i logitechmediaserver_7.9.2~1571644358_all.deb
USER squeezeboxserver
CMD /usr/sbin/squeezeboxserver --prefsdir /var/lib/squeezeboxserver/prefs --cachedir /var/lib/squeezeboxserver/cache --logdir /var/log/squeezeboxserver --charset utf8
