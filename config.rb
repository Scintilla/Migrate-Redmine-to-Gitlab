# Redmine connection data
HOST = 'https://host/redmine/'
API_KEY = 'someapikey'

# User conversion from Redmine => Gitlab, e.g. {15 => 1, 19 => 2}
USER_CONVERSION = {}
DEFAULT_ACCOUNT = 1

PROJECT_CONVERSION = {'example' => 'my_namespace/my_project'}
COPY_ISSUE_ID_FIELD = nil # e.g. :project_issue_id

# Custom features in Redmine (id)
CUSTOM_FEATURES = []

### Default values ###
HASH = 'redmine'
TARGET_TYPE = 'Issue'
DEBUG_ERROR = 4
DEBUG_WARNING = 3
DEBUG_STATUS = 2
DEBUG_DEBUG = 1
PRIORITIES = {3 => 'Low', 4 => 'Normal', 5 => 'High', 6 => 'Urgent', 7 => 'Immediate'}
OPEN_VALUES = ['New', 'In Progress', 'Feedback', 'Resolved']
CLOSED_VALUES = ['Closed', 'Rejected']

### Debug ###
DEBUG_STATE = DEBUG_DEBUG

def messenger(location, args)
  message = case location
              when 'connection_true' then
                [DEBUG_DEBUG, "Connection with #{args[0]} is established"]
              when 'connection_false' then
                [DEBUG_ERROR, "Connection with #{args[0]} failed"]
              when 'found_project' then
                [DEBUG_DEBUG, "Found Gitlab project: #{args[0]} from Redmine project: #{args[1]}"]
              when 'not_found_project' then
                [DEBUG_WARNING, "No Gitlab project found with the name: #{args[0]}"]
              when 'found_user' then
                [DEBUG_DEBUG, "Gitlab user: #{args[0]} found for Redmine user: #{args[1]} (#{args[2]})"]
              when 'not_found_user' then
                [DEBUG_WARNING, "No Gitlab user found for: #{args[0]} (#{args[1]}), using default account!"]
              when 'new_issue' then
                [DEBUG_DEBUG, "Created new issue: #{args}"]
              when 'issue_errors' then
                [DEBUG_ERROR, "#{args}"]
              when 'new_labels' then
                [DEBUG_DEBUG, "Adding labels: #{args[0]} to issue #{args[1]}"]
              when 'progress' then
                [DEBUG_STATUS, "#{args[0]}"]
              when 'journal_not_found' then
                [DEBUG_DEBUG, "Journal (#{args[0]}), was not transferred"]
              else
                [DEBUG_ERROR, "Error no message found for: #{location}, with args: #{args}"]
            end
  if message[0] >= DEBUG_STATE
    puts message[1]
  end
end




