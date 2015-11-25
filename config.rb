# Redmine connection data
Host   = "https://host/redmine/"
APIKey = "someapikey"

# User conversion from Redmine => Gitlab, e.g. {15 => 1, 19 => 2}
UserConversion = {}
DefaultAccount = 1

### Debug ###
Debug_state = DEBUG_ERROR

def messenger(location, args)
  message = case location
    when "connection_true" && Debug_state >= DEBUG_DEBUG then "Connection with " + args[0] + " is established"
    when "connection_false" && Debug_state >= DEBUG_ERROR then "Connection with " + args[0] + " failed"
    when "found_project" && Debug_state >= DEBUG_DEBUG then "Found Gitlab project: " + args[0] + " from Redmine project: " + args[1]
    when "not_found_project" && Debug_state >= DEBUG_WARNING then "No Gitlab project found with the name: " + args[0]
    when "found_user" && Debug_state >= DEBUG_DEBUG then "Gitlab user: " + args[0] + " found for Redmine user: " + args[1] + " " + args[2]
    when "not_found_user" && Debug_state >= DEBUG_WARNING then "No Gitlab user found for: " + args[0] + " " + args[1] + ", using default account!"
    when "new_issue" && Debug_state >= DEBUG_DEBUG then "Created new issue: " + args[0]
    when "issue_errors" && Debug_state >= DEBUG_ERROR then args[0]
    when "new_labels" && Debug_state >= DEBUG_DEBUG then "Adding labels: " + args[0] + " to issue " + args[1]
  end
  puts message
end



### Default values ###
TARGET_TYPE = "Issue"
DEBUG_ERROR = 3
DEBUG_WARNING = 2
DEBUG_DEBUG = 1
