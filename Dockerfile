# ==============================================================================
# Packaging only - this does not compile anything.
#
# `mvn package` runs first and this copies the fat jar it produced:
#
#   mvn -B package
#   docker build -t <namespace>/service-discovery:dev .
#
# Running Maven inside the image instead would mean a cold dependency
# download on every build, since a Docker layer cache cannot share the host's
# ~/.m2. The CI pipeline already builds the jar once in its own job, so this
# shape is what both paths want.
# ==============================================================================
FROM eclipse-temurin:21-jre-alpine

ARG JAR_FILE=target/service-discovery-0.0.1-SNAPSHOT.jar

WORKDIR /app
RUN addgroup -S app && adduser -S app -G app

COPY ${JAR_FILE} app.jar

USER app

# The Eureka default, and what k8s/service.yaml targets.
EXPOSE 8761

# MaxRAMPercentage, not -Xmx: the deployment sets a memory limit, so let the
# JVM size its heap from the cgroup limit it is actually given.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
