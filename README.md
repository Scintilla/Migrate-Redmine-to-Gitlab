# Migrate Redmine to Gitlab
Ruby script to transfer all tickets from Redmine to Gitlab

You need to have access to the gitlab console and an api key to redmine for this to work.

> This script worked for me. I take no responsibility for any damage or loss incurred as a result of using this script with or without changes made to it.

## Setup
* Clone this repo on the server where your gitlab is hosted.
* Edit the config.rb with the correct information (most important are `HOST`, `API_KEY` and `USER_CONVERSION`).
* Change the `DEBUG_STATE` for the amount of output you want.
* Execute the following command as a user that is allowed to use the gitlab console (e.g. gitlab or root)
```bash
gitlab-rails runner /path/to/repo/clone/migrate.rb -e production
```

## Versions
* Redmine version >=1.4
* GitLab Community Edition 8.0.4 1ff385d
* Ubuntu 14.04

## Notes
* Not editing `USER_CONVERSION` and `DEFAULT_ACCOUNT`, will result in all issues and comments to be linked to the root account of gitlab.
* Redmine can have custome features, if you want to add those to gitlab as labels add their id to `CUSTOM_FEATURES`.
* If your Redmine has custom piorities or statuses add them to the correct lists (`PRIORITIES`, `OPEN_VALUES` and `CLOSED_VALUES`).
* Script version 2.0
