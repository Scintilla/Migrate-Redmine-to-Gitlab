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

    def children
      @children ||= Issue.find(self.id, include: 'children').children
    end

    def attachments
      @attachments ||= Issue.find(self.id, include: 'attachments').attachments
    end

    def relations
      @relations ||= Issue.find(self.id, include: 'relations').relations
    end

    def changesets
      @changesets ||= Issue.find(self.id, include: 'changesets').changesets
    end
  end

  class Tracker < Base
    def self.find(id, options = {})
      list = self.list
      list.find { |s| s.id == Integer(id) }
    end
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

NOT_FOUND_USERS = []

def convert_user(rm_user)
  if rm_user.is_a?(Redmine::User)
    user_id = rm_user.id
    user_name = rm_user.firstname + ' ' + rm_user.lastname
  else
    user_id = rm_user['id']
    user_name = rm_user['name']
  end
  conv = USER_CONVERSION[user_id]
  if conv.nil? || conv.to_s.empty?
    unless NOT_FOUND_USERS.include? user_id
      NOT_FOUND_USERS << user_id
      messenger('not_found_user', [user_name, user_id])
    end
    gl_user = DEFAULT_ACCOUNT
  else
    messenger('found_user', [User.find(conv).name, user_name, user_id])
    gl_user = conv
  end
  gl_user
end

def check_label(title, gl_project_id, id = false)
  label = Label.find_by_title(title)
  if label.nil?
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
    label.id
  else
    title
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
  # Redmine issue => gitlab issue
  rm_issue_conv = {}
  gl_issues = {}
  nr_of_issues = 0
  first_issue = true
  first_issue_iid = 0
  gl_project = Project.find_by_name(rm_project.identifier)
  if gl_project != nil
    messenger('found_project', [gl_project.name, rm_project.name])

    gl_project_id = gl_project.id
    issue_offset = 0
    while true
      messenger('progress', ["#{issue_offset} issues processed"])
      rm_issues = rm_project.issues(:offset => issue_offset, :limit => 100)
      rm_issues.each do |issue|

        rm_user = issue.author
        gl_user_id = convert_user(rm_user)


        if ['New', 'In Progress', 'Feedback', 'Resolved'].include? issue.status['name']
          state = 'opened'
        else
          state = 'closed'
        end
        new_issue = Issue.new
        new_issue.title = issue.subject
        new_issue.state = state

        new_issue.author_id = gl_user_id
        new_issue.project_id = gl_project_id
        new_issue.created_at = issue.created_on

        description = issue.description
        if gl_user_id == DEFAULT_ACCOUNT
          description += "\n\n *Originally created by #{rm_user.firstname} #{rm_user.lastname} (Redmine)*"
        end
        if issue.assigned_to
          assignee = convert_user(issue.assigned_to)
          if assignee == DEFAULT_ACCOUNT
            description += "\n\n *Originally assigned to #{rm_user.firstname} #{rm_user.lastname} (Redmine)*"
          else
            new_issue.assignee_id = assignee
          end
        end
        new_issue.description = description

        messenger('new_issue', new_issue.title)
        unless new_issue.save
          messenger('issue_errors', [new_issue.errors.inspect])
        end
        if first_issue
          first_issue = false
          first_issue_iid = new_issue.iid - 1
        end
        rm_issue_conv[issue.id] = new_issue.iid
        gl_issues[issue] = new_issue

      end
      if rm_issues.length < 100
        nr_of_issues = issue_offset + rm_issues.length
        puts "#{nr_of_issues} issues processed"
        break
      end
      issue_offset += 100
    end
    messenger('progress', ['---\n\nAll issues progressed, adding additional data:\n\n'])
    gl_issues.each do |rm_issue, gl_issue|
      labels = []
      journals = rm_issue.notes

      status_changed = false
      priority_changed = false
      category_changed = false
      tracker_changed = false
      parent_changed = false
      first_assignee = true

      journals.each do |journal|
        if !journal['notes'].nil? && !journal['notes'].empty?
          create_note(journal['notes'], convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id, false)
        end
        unless journal['details'].empty?
          old = []
          new = []
          journal['details'].each do |detail|
            if detail['property'] == 'attr'
              if detail['name'] == 'status_id'
                status_changed = true
                if detail['new_value']
                  new << check_label('Status: ' + Redmine::IssueStatus.find(detail['new_value']).name, gl_project_id, true)
                end
                if detail['old_value']
                  old << check_label('Status: ' + Redmine::IssueStatus.find(detail['old_value']).name, gl_project_id, true)
                end
              elsif detail['name'] == 'priority_id'
                priority_changed = true
                if detail['new_value']
                  new << check_label('Priority: ' + PRIORITIES[Integer(detail['new_value'])], gl_project_id, true)
                end
                if detail['old_value']
                  old << check_label('Priority: ' + PRIORITIES[Integer(detail['old_value'])], gl_project_id, true)
                end
              elsif detail['name'] == 'assigned_to_id'
                if !detail['old_value'].nil? && first_assignee
                  first_assignee = false
                  user = Redmine::User.find(detail['old_value'])
                  if convert_user(user) == DEFAULT_ACCOUNT
                    feature = "Reassigned to #{user.firstname} #{user.lastname} (Redmine)"
                  else
                    gl_user = User.find(convert_user(user))
                    feature = "Reassigned to @#{gl_user.username}"
                  end
                  create_note(feature, convert_user(journal['user']), rm_issue.created_on, gl_project_id, gl_issue.id)
                end
                if detail['new_value']
                  user = Redmine::User.find(detail['new_value'])
                  if convert_user(user) == DEFAULT_ACCOUNT
                    feature = "Reassigned to #{user.firstname} #{user.lastname} (Redmine)"
                  else
                    gl_user = User.find(convert_user(user))
                    feature = "Reassigned to @#{gl_user.username}"
                  end
                  create_note(feature, convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                end
              elsif detail['name'] == 'category_id'
                category_changed = true
                if detail['new_value']
                  new << check_label(Redmine::IssueCategory.find(detail['new_value']).name, gl_project_id, true)
                end
                if detail['old_value']
                  old << check_label(Redmine::IssueCategory.find(detail['old_value']).name, gl_project_id, true)
                end
              elsif detail['name'] == 'tracker_id'
                tracker_changed = true
                if detail['new_value']
                  new << check_label(Redmine::Tracker.find(detail['new_value']).name, gl_project_id, true)
                end
                if detail['old_value']
                  old << check_label(Redmine::Tracker.find(detail['old_value']).name, gl_project_id, true)
                end
              elsif detail['name'] == 'parent_id'
                parent_changed = true
                description = gl_issue.description || ''
                if !detail['old_value'].nil?
                  description.slice! "\n\n **Parent issue: ##{rm_issue_conv[Integer(detail['old_value'])]}**"
                  if !detail['new_value'].nil?
                    description += "\n\n **Parent issue: ##{rm_issue_conv[Integer(detail['new_value'])]}**"
                    create_note("Changed parent issue from ##{rm_issue_conv[Integer(detail['old_value'])]} to ##{rm_issue_conv[Integer(detail['new_value'])]}", convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                  else
                    create_note("Parent issue ##{rm_issue_conv[Integer(detail['old_value'])]} removed", convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                  end
                elsif !detail['new_value'].nil?
                  description += "\n\n **Parent issue: ##{rm_issue_conv[Integer(detail['new_value'])]}**"
                  create_note("Added parent issue ##{rm_issue_conv[Integer(detail['new_value'])]}", convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                end
                gl_issue.description = description
              end
            elsif CUSTOM_FEATURES.include? detail['name']
              if detail['new_value']
                new << check_label(detail['new_value'], gl_project_id, true)
              end
              if detail['old_value']
                old << check_label(detail['old_value'], gl_project_id, true)
              end
            else
              #TODO some message
            end
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
            create_note(string, convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
          end
        end
      end

      if !status_changed && !rm_issue.status.nil?
        labels << check_label('Status: ' + Redmine::IssueStatus.find(rm_issue.status['id']).name, gl_project_id)
      end
      if !priority_changed && !rm_issue.priority.nil?
        labels << check_label('Priority: ' + rm_issue.priority['name'], gl_project_id)
      end
      if !category_changed && !rm_issue.category.nil?
        labels << check_label(rm_issue.category['name'], gl_project_id)
      end
      if !tracker_changed && !rm_issue.tracker.nil?
        labels << check_label(rm_issue.tracker['name'], gl_project_id)
      end
      if !parent_changed && !rm_issue.parrent.nil?
        description = gl_issue.description || ''
        description += "\n\n **Parent issue: ##{rm_issue_conv[Integer(rm_issue.parrent['id'])]}**"
        gl_issue.description = description
      end
      messenger('new_labels', [labels, gl_issue.id])
      gl_issue.add_labels_by_names(labels)
      gl_issue.updated_at = rm_issue.updated_on

      unless gl_issue.save
        messenger('issue_errors', [gl_issue.errors.inspect])
      end

      done = (gl_issue.iid - first_issue_iid).to_f / nr_of_issues.to_f * 100.0
      if done % 5 < 0.1
        messenger('progress', ["#{done.round}% done"])
      end
    end
    messenger('progress', ["#{rm_project.identifier} done"])
  else
    messenger('not_found_project', [rm_project.identifier])
  end
end

