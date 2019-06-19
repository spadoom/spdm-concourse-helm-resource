#!/bin/bash
docker build -t spadoom/concourse-helm-resource .
docker tag spadoom/concourse-helm-resource spadoom/concourse-helm-resource:1.1.1
docker push spadoom/concourse-helm-resource:1.1.1
docker push spadoom/concourse-helm-resource:latest
