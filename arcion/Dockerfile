FROM eclipse-temurin:20-jre
RUN apt-get -y update
RUN apt-get -y upgrade
RUN apt-get -y install unzip
RUN curl -sL https://arcion-releases.s3.us-west-1.amazonaws.com/general/replicant/replicant-cli-$REPLICANT_VERSION.zip -o /usr/local/replicant.zip && \
unzip -qq /usr/local/replicant.zip -d /usr/local && \
rm /usr/local/replicant.zip
WORKDIR /usr/local/replicant-cli