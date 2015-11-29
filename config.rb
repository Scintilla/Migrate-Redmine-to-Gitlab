# Redmine connection data
Host   = "https://host/redmine/"
APIKey = "someapikey"

# User conversion from Redmine => Gitlab, e.g. {15 => 1, 19 => 2}
UserConversion = {}
DefaultAccount = 1

CustomFeatures = []

### Default values ###
TARGET_TYPE = "Issue"
DEBUG_ERROR = 3
DEBUG_WARNING = 2
DEBUG_DEBUG = 1

### Debug ###
Debug_state = DEBUG_ERROR

def messenger(location, args)
  message = case location
    when "connection_true" then [DEBUG_DEBUG, "Connection with #{args[0]} is established"]
    when "connection_false" then [DEBUG_ERROR, "Connection with #{args[0]} failed"]
    when "found_project" then [DEBUG_DEBUG, "Found Gitlab project: #{args[0]} from Redmine project: #{args[1]}"]
    when "not_found_project" then [DEBUG_WARNING, "No Gitlab project found with the name: #{args[0]}"]
    when "found_user" then [DEBUG_DEBUG, "Gitlab user: #{args[0]} found for Redmine user: #{args[1]} #{args[2]}"]
    when "not_found_user" then [DEBUG_WARNING, "No Gitlab user found for: #{args[0]} #{args[1]}, using default account!"]
    when "new_issue" then [DEBUG_DEBUG, "Created new issue: #{args[0]}"]
    when "issue_errors" then [DEBUG_ERROR, "#{args[0]}"]
    when "new_labels" then [DEBUG_DEBUG, "Adding labels: #{args[0]} to issue #{args[1]}"]
  end
  if message[0] >= Debug_state
    puts message[1]
  end
end




