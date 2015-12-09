#!/usr/bin/env ruby

require 'faraday'
require 'json'
require 'gitlab'
require_relative 'config'

module Redmine
  def self.connection
    raise 'must define a Host' if HOST.nil?
    @connection ||= Faraday.new(:url => HOST) do |faraday|
      faraday.adapter Faraday.default_adapter
    end
  end

  def self.test_connection
    res = connection.get('/')
    if res.status.to_s.start_with?('2', '3')
      messenger('connection_true', [HOST])
    else
      messenger('connection_false', [HOST])
    end
  end

  def self.get(path, attrs = {})
    raise 'must define an APIKey' if API_KEY.nil?
    result = connection.get(path, attrs) do |req|
      req.headers['X-Redmine-API-Key'] = API_KEY
    end
    JSON.parse result.body
  end

  class Base
    attr_accessor :id, :attributes

    def self.pluralized_resource_name
      @pluralized_resource_name ||= "#{self.resource_name}s"
    end

    def self.resource_name
      @resource_name ||= self.name.split('::').last.downcase
    end

    def self.list(options = {})
      list = Redmine.get "#{pluralized_resource_name}.json", options

      raise "did not find any #{pluralized_resource_name} in #{list.inspect}" if list[pluralized_resource_name].nil?

      list[pluralized_resource_name].collect do |attributes|
        obj = new
        obj.attributes = attributes
        obj
      end
    end

    def self.find(id, options = {})
      @find ||= {}
      return @find[id] if @find[id]

      response = Redmine.get "#{pluralized_resource_name}/#{id}.json", options
      obj = new
      obj.attributes = response[resource_name]
      @find[id] = obj
    end

    def method_missing(sym, *args)
      self.attributes[sym.to_s]
    end

    def id
      self.attributes['id']
    end
  end

  class Project < Base
    def issues(options = {})
      @issues = Issue.list(options.merge(:status_id => '*', :project_id => self.id, :subproject_id => '!*', :sort => 'id:asc'))
    end

    def categories
      @categories ||= IssueCategory.list :project_id => self.id
    end

    def category_by_name(name)
      @category_by_name ||= {}
      @category_by_name[name] ||= categories.detect { |category| category.name == name }
    end

    def self.by_identifier(identifier)
      self.list(:limit => 1000).detect { |project| project.identifier == identifier }
    end
  end

  class User < Base
    def self.by_email(email)
      @by_email ||= {}
      @by_email[email] ||= self.list.detect { |user| user.mail == email }
    end
  end

  class Issue < Base
    def self.create(project, subject, description, attributes = {})
      body = {
          :issue => {
              :project_id => project.id,
              :subject => subject,
              :description => description,
              :tracker_id => Tracker.first.id,
              :priority_id => 4
          }.merge(attributes)
      }.to_json
      return body
    end

    def author
      Redmine::User.find self.attributes['author']['id']
    end

    def assignee
      Redmine::User.find self.attributes['assigned_to']['id'] rescue nil
    end

    def notes
      @journals ||= Issue.find(self.id, include: 'journals').journals
    end
  end

  class Tracker < Base
  end

  class IssueStatus < Base
    def self.pluralized_resource_name;
      'issue_statuses';
    end

    def self.resource_name;
      'issue_status';
    end

    def self.by_name(name)
      @by_name ||= {}
      @by_name[name] ||= list.detect { |status| status.name == name }
    end

    def self.find(id, options = {})
      list = self.list
      list.find { |s| s.id == Integer(id) }
    end
  end

  class IssueCategory < Base
    def self.pluralized_resource_name;
      'issue_categories';
    end

    def self.pluralized_project_name;
      'projects';
    end

    def self.resource_name;
      'issue_category';
    end

    def self.list(options = {})
      raise 'must provide a project_id' if options[:project_id].nil?
      list = Redmine.get "#{pluralized_project_name}/#{options[:project_id]}/#{pluralized_resource_name}"
      raise "did not find any issue_categories in #{list.inspect}" if list['issue_categories'].nil?
      list['issue_categories'].collect do |attributes|
        obj = new
        obj.attributes = attributes
        obj
      end
    end
  end

  class Tracker < Base
    def self.first
      @first ||= self.list.first
    end
  end
end

def convert_user(rm_user)
  conv = USER_CONVERSION[rm_user.id]
  if conv.nil? || conv.to_s.empty?
    messenger('not_found_user', [rm_user.firstname, rm_user.lastname])
    gl_user = DEFAULT_ACCOUNT
  else
    messenger('found_user', [User.find(conv).name, rm_user.firstname, rm_user.lastname])
    gl_user = conv
  end
  gl_user
end

def check_label(title, id = false)
  if Label.find_by_title(title).nil?
    new_label = Label.new
    new_label.project_id = gl_project_id
    new_label.title = title
    new_label.save
    if !id
      new_label.title
    else
      new_label.id
    end
  elsif id
    Label.find_by_title(title).id
  else
    Label.find_by_title(title).title
  end
end

def create_note(title, author, date, project, issue, system=true)
  new_note = Note.new
  new_note.note = title
  new_note.noteable_type = TARGET_TYPE
  new_note.author_id = author
  new_note.created_at = date
  new_note.updated_at = date
  new_note.project_id = project
  new_note.noteable_id = issue
  new_note.system = system
  new_note.save
end


Redmine.test_connection

rm_projects = Redmine::Project.list

rm_projects.each do |rm_project|
  gl_project = Project.find_by_name(rm_project.identifier)
  if gl_project != nil
    messenger('found_project', [gl_project.name, rm_project.name])

    gl_project_id = gl_project.id
    issue_offset = 0
    while issue_offset < 10
      # puts i
      rm_issues = rm_project.issues(:offset => issue_offset, :limit => 10)
      rm_issues.each do |issue|

        rm_user = issue.author
        gl_user_id = convert_user(rm_user)
        #TODO add first user to description
        if ['New', 'In Progress', 'Feedback'].include? issue.status['name']
          state = 'opened'
        else
          state = 'closed'
        end
        new_issue = Issue.new
        new_issue.title = issue.subject
        new_issue.state = state
        unless issue.assigned_to.nil?
          new_issue.assignee_id = issue.assigned_to['id']
        end

        new_issue.author_id = gl_user_id
        new_issue.project_id = gl_project_id
        new_issue.created_at = issue.created_on
        new_issue.updated_at = issue.updated_on
        new_issue.description = issue.description
        messenger('new_issue', new_issue.title)
        unless new_issue.save
          messenger('issue_errors', [issues.errors])
        end
        labels = []
        journals = issue.notes

        priority_changed = false
        category_changed = false
        tracker_changed = false
        parent_changed = false
        first_assignee = true

        journals.each do |journal|
          unless journal['details'].empty?
            old = []
            new = []
            journal['details'].each do |detail|
              if detail['property'] == 'attr'
                if detail['name'] == 'status_id'
                  unless detail['new_value'].nil?
                    new << check_label(Redmine::IssueStatus.find(detail['new_value'])['name'], true)
                  end
                  unless detail['old_value'].nil?
                    old << check_label(Redmine::IssueStatus.find(detail['old_value'])['name'], true)
                  end
                elsif detail['name'] == 'priority_id'
                  unless detail['new_value'].nil?
                    new << check_label(PRIORITIES[detail['new_value']], true)
                  end
                  unless detail['old_value'].nil?
                    old << check_label(PRIORITIES[detail['old_value']], true)
                  end
                elsif detail['name'] == 'assigned_to_id'
                  unless detail['new_value'].nil?
                    user = Redmine::User.find(detail['new_value'])
                    if convert_user(user) == DEFAULT_ACCOUNT
                      feature = "Reassigned to #{user.firstname} #{user.lastname} (Redmine)"
                    else
                      gl_user = User.find(convert_user(user))
                      feature = "Reassigned to @#{gl_user.username}"
                    end
                    create_note(feature, convert_user(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
                  end
                  if !detail['old_value'].nil? && first_assignee
                    first_assignee = false
                    user = Redmine::User.find(detail['old_value'])
                    if convert_user(user) == DEFAULT_ACCOUNT
                      feature = "Reassigned to #{user.firstname} #{user.lastname} (Redmine)"
                    else
                      gl_user = User.find(convert_user(user))
                      feature = "Reassigned to @#{gl_user.username}"
                    end
                    create_note(feature, convert_user(journal['user']), issue.created_on, gl_project_id, new_issue.id)
                  end
                elsif detail['name'] == 'category_id'
                  unless detail['new_value'].nil?
                    new << check_label(Redmine::IssueCategory.find(detail['new_value'])['name'], true)
                  end
                  unless detail['old_value'].nil?
                    old << check_label(Redmine::IssueCategory.find(detail['old_value'])['name'], true)
                  end
                elsif detail['name'] == 'tracker_id'
                  unless detail['new_value'].nil?
                    new << check_label(Redmine::Tracker.find(detail['new_value'])['name'], true)
                  end
                  unless detail['old_value'].nil?
                    old << check_label(Redmine::Tracker.find(detail['old_value'])['name'], true)
                  end
                elsif detail['name'] == 'parent_id'
                  if not detail['old_value'].nil?
                    new_issue.description.slice! "\n\n ** Parent issue: ##{detail['old_value']}"
                    create_note("~~ Parent issue: ##{detail['old_value']} ~~", convert_user(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
                  elsif not detail['new_value'].nil?
                    new_issue.description << "\n\n ** Parent issue: ##{detail['new_value']}"
                    create_note("Added Parent issue: ##{detail['new_value']} ~~", convert_user(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
                  end
                end
              elsif CUSTOM_FEATURES.include? detail['name']
                unless detail['new_value'].nil?
                  new << check_label(detail['new_value'])
                end
                unless detail['old_value'].nil?
                  old << check_label(detail['old_value'])
                end
              else
                #TODO some message
              end
              if !old.empty? or !new.empty?
                if not old.empty?
                  if not new.empty?
                    string = 'Added '
                    new.each { |id| string << "~#{id} " }
                    string << 'and removed '
                    old.each { |id| string << "~#{id} " }
                    string << 'labels'
                  elsif old.length > 1
                    string = 'Removed '
                    old.each { |id| string << "~#{id} " }
                    string << 'labels'
                  else
                    string = "Remove ~#{old[0]} label"
                  end
                else
                  if new.length > 1
                    string = 'Added '
                    new.each { |id| string << "~#{id} " }
                    string << 'labels'
                  else
                    string = "Remove ~#{new[0]} label"
                  end
                end
                create_note(string, convert_user(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
              end
            end
          end
          unless journal['notes'].empty?
            create_note(journal['notes'], convert_user(journal['user']), journal['created_on'], gl_project_id, new_issue.id, false)
          end
        end

        #TODO add status as label
        if !parent_changed && !issue.parrent.nil?
          # TODO add line to description with parent
        end
        if !category_changed && !issue.category.nil?
          labels << check_label(issue.category['name'])
        end
        if !priority_changed && !issue.priority.nil?
          labels << check_label(issue.priority['name'])
        end
        if !tracker_changed && !issue.tracker.nil?
          labels << check_label(issue.tracker['name'])
        end
        messenger('new_labels', [labels, new_issue.id])
        new_issue.add_labels_by_names(labels)

      end
      break if rm_issues.length < 100
      issue_offset += 100
    end
  else
    messenger('not_found_project', [rm_project.identifier])
  end
end

