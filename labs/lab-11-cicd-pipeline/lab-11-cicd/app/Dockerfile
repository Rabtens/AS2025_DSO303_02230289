# The USMS enrolment service: a static portal served by nginx.
# The build context must already contain dist/, produced by buildspec.yml's build phase.
FROM nginx:1.27-alpine

# Copy the BUILT output, not the source tree.
COPY dist/ /usr/share/nginx/html/

# Lab 04's task definition health check fetches http://localhost/ and Lab 05's
# target group health check fetches / on the traffic port. Both need port 80.
EXPOSE 80

# nginx:alpine's own entrypoint already runs nginx in the foreground.
