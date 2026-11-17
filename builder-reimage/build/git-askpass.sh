#!/bin/sh
# GIT_ASKPASS helper: answers git's password prompt with the GitHub App
# installation token from the environment (withCredentials GITHUB_TOKEN).
printf '%s\n' "$GITHUB_TOKEN"
