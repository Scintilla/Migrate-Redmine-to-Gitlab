#!/usr/bin/env ruby

require 'faraday'
require 'json'
require 'gitlab'
require_relative 'config'

module Redmine
  def self.connection
    raise 'must define a Host' if Host.nil?;
    @connection ||= Faraday.new(:url => Host) do |faraday|
      faraday.adapter   Faraday.default_adapter
    end
  end

  def self.testconnection
    res = connection.get("/")
    if res.status.to_s.start_with?('2', '3')
      messenger("connection_true", [Host])
    else
      messenger("connection_false", [Host])
    end
  end

  def self.get(path, attrs = {})
    raise 'must define an APIKey' if APIKey.nil?
    result = connection.get(path, attrs) do |req|
      req.headers['X-Redmine-API-Key'] = APIKey
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
          :project_id       => project.id,
          :subject          => subject,
          :description      => description,
          :tracker_id       => Tracker.first.id,
          :priority_id      => 4
        }.merge(attributes)
      }.to_json
    end

    def author
      Redmine::User.find self.attributes['author']['id']
    end

    def assignee
      Redmine::User.find self.attributes['assigned_to']['id'] rescue nil
    end

    def notes
      @journals ||= Issue.find(self.id, include: "journals").journals
    end
  end

  class Tracker < Base
  end

  class IssueStatus < Base
    def self.pluralized_resource_name ; 'issue_statuses' ; end
    def self.resource_name ;            'issue_status' ; end

    def self.by_name(name)
      @by_name ||= {}
      @by_name[name] ||= list.detect { |status| status.name == name }
    end
  end

  class IssueCategory < Base
    def self.pluralized_resource_name ; 'issue_categories' ; end
    def self.pluralized_project_name ; 'projects' ; end
    def self.resource_name ;            'issue_category' ; end

    def self.list(options = {})
      raise "must provide a project_id" if options[:project_id].nil?
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

def convertUser(rm_user)
  conv =  UserConversion[rm_user.id]
  if conv.nil? || conv.to_s.empty?
    messenger("not_found_user", [rm_user.firstname, rm_user.lastname])
    gl_user = DefaultAccount
  else
    messenger("found_user", [User.find(conv).name,  issue.author.firstname, rm_user.lastname])
    gl_user = conv
  end
end

def checklabel(title, id = false)
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

def createNote(title, author, date, project, issue, system=true)
  new_note = Note.new
  new_note.note = title
  new_note.noteable_type = TARGET_TYPE
  new_note.author_id = author
  new_note.created_at = date
  new_note.updated_at = date
  new_note.project_id = project
  new_note.noteable_id = issue
  new_note.system = system
end



Redmine.testconnection

rm_projects = Redmine::Project.list

rm_projects.each do |rm_project|
  gl_project = Project.find_by_name(rm_project.identifier)
  if gl_project != nil
    messenger("found_project", [gl_project.name, rm_project.name])
    
    gl_project_id = gl_project.id
    issue_offset = 0
    while issue_offset < 10
      # puts i
      rm_issues = rm_project.issues(:offset => issue_offset, :limit => 10)
      rm_issues.each do |issue|

        rm_user = issue.author
        gl_user_id = convertUser(rm_user)
        #TODO add first user to description
        if ["New", "In Progress", "Feedback"].include? issue.status['name']
          state = "opened"
        else
          state = "closed"
        end
        new_issue = Issue.new
        new_issue.title = issue.subject
        if not issue.assigned_to.nil?
          new_issue.assignee_id = issue.assigned_to['id']
        end

        new_issue.author_id = creator_id
        new_issue.project_id = gl_project_id
        new_issue.created_at = issue.created_on     
        new_issue.updated_at = issue.updated_on     
        new_issue.description = issue.description
        messenger("new_issue", new_issue.title)
        if new_issue.save == false
          messenger("issue_errors", [issues.errors])
        end
        labels = []
        journals = issue.notes
        
        priority_changed = false
        category_changed = false
        tracker_changed  = false
        parent_changed   = false
        first_assignee   = true
 
        journals.each do |journal|
          if not journal['details'].empty?
            old = []
            new = []
            journal['details'].each do |detail|
              if detail['property'] == "attr"
                if detail['name'] == "status_id"
                  if not detail['new_value'].nil?
                    new << checklabel(Redmine::IssueStatus.find(detail['new_value'])['name'], true)
                  end
                  if not detail['old_value'].nil?
                    old << checklabel(Redmine::IssueStatus.find(detail['old_value'])['name'], true)
                  end
                elsif detail['name'] == "priority_id"
                  if not detail['new_value'].nil?
                    new << checklabel(Priorities[detail['new_value']], true)
                  end
                  if not detail['old_value'].nil?
                    old << checklabel(Priorities[detail['old_value']], true)
                  end
                elsif detail['name'] == "assigned_to_id"
                  if not detail['new_value'].nil?
                    user = Redmine::User.find(detail['new_value'])
                    if convertUser(user) == DefaultAccount
                      feature = "Reassigned to #{user.firstname} #{user.lastname} (Redmine)"
                    else
                      gl_user = User.find(convertUser(user))
                      feature = "Reassigned to @#{gl_user.username}"
                    end
                    createNote(feature, convertUser(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
                  end
                  if !detail['old_value'].nil? && first_assignee
                    first_assignee = false
                    user = Redmine::User.find(detail['old_value'])
                    if convertUser(user) == DefaultAccount
                      feature = "Reassigned to #{user.firstname} #{user.lastname} (Redmine)"
                    else
                      gl_user = User.find(convertUser(user))
                      feature = "Reassigned to @#{gl_user.username}"
                    end
                    createNote(feature, convertUser(journal['user']), issue.created_on, gl_project_id, new_issue.id)
                  end
                elsif detail['name'] == "category_id"
                  if not detail['new_value'].nil?
                    new << checklabel(Redmine::IssueCategory.find(detail['new_value'])['name'], true)
                  end
                  if not detail['old_value'].nil?
                    old << checklabel(Redmine::IssueCategory.find(detail['old_value'])['name'], true)
                  end
                elsif detail['name'] == "tracker_id"
                  if not detail['new_value'].nil?
                    new << checklabel(Redmine::Tracker.find(detail['new_value'])['name'], true)
                  end
                  if not detail['old_value'].nil?
                    old << checklabel(Redmine::Tracker.find(detail['old_value'])['name'], true)
                  end
                elsif detail['name'] == "parent_id"
                  if not detail['old_value'].nil?
                    new_issue.description.slice! "\n\n ** Parent issue: ##{detail['old_value']}"
                    createNote("~~ Parent issue: ##{detail['old_value']} ~~", convertUser(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
                  elsif not detail['new_value'].nil?
                    new_issue.description << "\n\n ** Parent issue: ##{detail['new_value']}"
                    createNote("Added Parent issue: ##{detail['new_value']} ~~", convertUser(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
                  end
                end
              elsif CustomFeatures.contains? detail['name']
                if not detail['new_value'].nil?
                  new << checklabel(detail['new_value'])
                end
                if not detail['old_value'].nil?
                  old << checklabel(detail['old_value'])
                end
              else
                #TODO some message
              end
              if !old.empty? or !new.empty?
                if not old.empty?
                  if not new.empty?
                    string = "Added "
                    new.each { |id| string << "~#{id} " }
                    string << "and removed "
                    old.each { |id| string << "~#{id} " }
                    string << "labels"
                  elsif old.length > 1
                    string = "Removed "
                    old.each { |id| string << "~#{id} " }
                    string << "labels"
                  else
                    string = "Remove ~#{old[0]} label"
                  end
                elsif not new.empty?
                  if new.length > 1
                    string = "Added "
                    new.each { |id| string << "~#{id} " }
                    string << "labels"
                  else
                    string = "Remove ~#{new[0]} label"
                  end
                end
                createNote(string, convertUser(journal['user']), journal['created_on'], gl_project_id, new_issue.id)
              end
            end
          end
          if not journal['notes'].empty?
            createNote(journal['notes'], convertUser(journal['user']), journal['created_on'], gl_project_id, new_issue.id, false)
          end
        end

        #TODO add status as label
        if !parent_changed && !issue.parrent.nil?
          #TODO add line to decription with parent
        end
        if !category_changed && !issue.category.nil?
          labels << checklabel(issue.category['name'])
        end
        if !priority_changed && !issue.priority.nil?
          labels << checklabel(issue.priority['name'])
        end
        if !tracker_changed && !issue.tracker.nil?
          labels << checklabel(issue.tracker['name'])
        end
        messenger("new_labels", [labels, new_issue.id])
        new_issue.add_labels_by_names(labels)

      end
      break if rm_issues.length < 100
      issue_offset += 100
    end
  else
    messenger("not_found_project", [rm_project.identifier])
  end
end

