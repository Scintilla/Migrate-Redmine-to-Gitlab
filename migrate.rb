#!/usr/bin/env ruby

require 'faraday'
require 'json'
require 'gitlab'
require 'config'

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

def checklabel(title)
  if Label.find_by_title(issue.category['name']).nil?
    new_label = Label.new
    new_label.project_id = gl_project_id
    new_label.title = issue.category['name']
    new_label.save
    new_label.title
  else
    Label.find_by_title(issue.category['name']).title
  end
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
        gl_user_id =  userconversion[rm_user.id]
        default = false
        if gl_user_id.nil? || gl_user_id.to_s.empty?
          messenger("not_found_user", [rm_user.firstname, rm_user.lastname])
          default = true
          creator_id = DefaultAccount
          #TODO add first user to description
        else
          messenger("found_user", [User.find(gl_user_id).name,  issue.author.firstname, rm_user.lastname])
          creator_id = gl_user_id
        end
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
        messenger("new_issue", new_issue.inspect)
        if new_issue.save == false
          messenger("issue_errors", [issues.errors])
        end
        labels = []
        journals = issue.notes
        
        category_changed = false
        priority_changed = false
        tracker_changed  = false
        parent_changed   = false
 
        journals.each do |journal|
          if not journal['details'].empty?
            journal['details'].each do |detail|
              detail['name']
            end
        end
        if not (parent_changed && issue.parrent.nil?)
          #TODO add line to decription with parent
        end
        if not (category_changed && issue.category.nil?)
          labels << checklabel(issue.category['name'])
        end
        if not (priority_changed && issue.priority.nil?)
          labels << checklabel(issue.priority['name'])
        end
        if not (tracker_changed && issue.tracker.nil?)
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

