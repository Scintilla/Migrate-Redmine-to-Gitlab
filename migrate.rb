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
      @find = {}
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

    def ls_children
      Issue.find(self.id, include: 'children').children
    end

    def ls_attachments
      Issue.find(self.id, include: 'attachments').attachments
    end

    def ls_relations
      Issue.find(self.id, include: 'relations').relations
    end

    def ls_changesets
      Issue.find(self.id, include: 'changesets').changesets
    end

    def ls_journals
      Issue.find(self.id, include: 'journals').journals
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

def check_label(title, gl_project_id, id = false, color = nil)
  label = Label.find_by_title(title)
  if label.nil?
    new_label = Label.new
    new_label.project_id = gl_project_id
    new_label.title = title
    if color
      new_label.color = color
    end
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

def create_note(title, author, date, project, issue, system=true, event=false)
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
  if event
    create_event(new_note, author, Event::COMMENTED, date)
  end
end

def create_event(record, user_id, status, date, attributes = {})
  attributes.merge!(
      project: record.project,
      action: status,
      author_id: user_id,
      created_at: date,
      updated_at: date,
      target_id: record.id,
      target_type: record.class.name
  )

  Event.create(attributes)
end

Redmine.test_connection
if PROJECT_CONVERSION.empty?
  rm_projects = Redmine::Project.list
else
  rm_projects = PROJECT_CONVERSION
end

rm_projects.each do |rm_p|
  # Redmine issue => gitlab issue
  if PROJECT_CONVERSION.empty?
    rm_project = rm_p
    gl_project = Project.find_by_name(rm_project.identifier)
  else
    rm_project = Redmine::Project.by_identifier(rm_p[0])
    gl_project = Project.find_by_name(rm_p[1])
  end

  rm_issue_conv = {}
  gl_issues = {}
  nr_of_issues = 0
  first_issue = true
  first_issue_iid = 0
  if gl_project != nil
    messenger('found_project', [gl_project.name, rm_project.name])
    messenger('progress', ["--- Starting processing #{rm_project.identifier} (step 1 of 2)"])
    gl_project_id = gl_project.id
    issue_offset = 0
    while true
      rm_issues = rm_project.issues(:offset => issue_offset, :limit => 100)
      rm_issues.each do |issue|
        if issue_offset % 20 == 0
          messenger('progress', ["#{issue_offset} issues processed"])
        end
        issue_offset += 1

        rm_user = issue.author
        gl_user_id = convert_user(rm_user)

        if OPEN_VALUES.include? issue.status['name']
          state = 'opened'
        else
          state = 'closed'
        end
        issue.inspect
        new_issue = Issue.new
        new_issue.title = issue.subject
        new_issue.state = state

        new_issue.author_id = gl_user_id
        new_issue.project_id = gl_project_id
        new_issue.created_at = issue.created_on

        description = issue.description
        description.gsub! '\r\n', '\n\n'
        description.gsub! '<pre>', '```'
        description.gsub! '</pre>', '```'
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

        create_event(new_issue, gl_user_id, Event::CREATED, new_issue.created_at)

        if first_issue
          first_issue = false
          first_issue_iid = new_issue.iid - 1
        end
        rm_issue_conv[issue.id] = new_issue
        gl_issues[issue] = new_issue

      end
      if rm_issues.length < 100
        nr_of_issues = issue_offset
        messenger('progress', ["#{nr_of_issues} issues processed"])
        break
      end
    end
    messenger('progress', ['--- All issues processed, adding additional data (step 2 of 2):'])
    gl_issues.each do |rm_issue, gl_issue|
      done = (gl_issue.iid - first_issue_iid).to_f / nr_of_issues.to_f * 100.0
      if done % 5 < 0.1
        messenger('progress', ["#{done.round}% done"])
      end
      labels = []
      journals = rm_issue.ls_journals

      parent_changed = false
      first_assignee = true

      journals.each do |journal|
        redmine_text = ''
        if convert_user(journal['user']) == DEFAULT_ACCOUNT
          redmine_text = "*#{journal['user']['name']} (Redmine)*/n/n"
        end
        if !journal['notes'].nil? && !journal['notes'].empty?
          note = journal['notes']
          if note.include? 'Applied in changeset commit:'
            note.slice! 'commit:'
          end
          note.gsub! '\r\n', '\n\n'
          note.gsub! '<pre>', '```'
          note.gsub! '</pre>', '```'
          create_note(redmine_text+note, convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id, false, true)
        end
        unless journal['details'].empty?
          old = []
          new = []
          journal['details'].each do |detail|
            if detail['property'] == 'attr'
              if detail['name'] == 'status_id'
                if detail['new_value']
                  new << check_label('Status: ' + Redmine::IssueStatus.find(detail['new_value']).name, gl_project_id, true)
                end
                if detail['old_value']
                  old << check_label('Status: ' + Redmine::IssueStatus.find(detail['old_value']).name, gl_project_id, true)
                end
                if CLOSED_VALUES.include? detail['new_value'] and OPEN_VALUES.include? detail['old_value']
                  create_event(gl_issue, convert_user(journal['user']), Event::CLOSED, journal['created_on'])
                elsif OPEN_VALUES.include? detail['new_value'] and CLOSED_VALUES.include? detail['old_value']
                  create_event(gl_issue, convert_user(journal['user']), Event::REOPENED, journal['created_on'])
                end
              elsif detail['name'] == 'priority_id'
                if detail['new_value']
                  new << check_label('Priority: ' + PRIORITIES[Integer(detail['new_value'])], gl_project_id, true)
                end
                if detail['old_value']
                  old << check_label('Priority: ' + PRIORITIES[Integer(detail['old_value'])], gl_project_id, true)
                end
              elsif detail['name'] == 'assigned_to_id'
                if detail['old_value']
                  if first_assignee
                    user = Redmine::User.find(detail['old_value'])
                    if convert_user(user) == DEFAULT_ACCOUNT
                      feature = "Reassigned to #{user.firstname} #{user.lastname} (Redmine)"
                    else
                      gl_user = User.find(convert_user(user))
                      feature = "Reassigned to @#{gl_user.username}"
                    end
                    create_note(feature, convert_user(journal['user']), rm_issue.created_on, gl_project_id, gl_issue.id)
                  elsif detail['new_value'].nil?
                    feature = 'Assignee removed'
                    create_note(feature, convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                  end
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
                first_assignee = false
              elsif detail['name'] == 'category_id'
                if detail['new_value']
                  new << check_label(Redmine::IssueCategory.find(detail['new_value']).name, gl_project_id, true, '#12AD2B')
                end
                if detail['old_value']
                  old << check_label(Redmine::IssueCategory.find(detail['old_value']).name, gl_project_id, true, '#12AD2B')
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
                  description.slice! "\n\n **Parent issue: ##{rm_issue_conv[Integer(detail['old_value'])].iid}**"
                  if !detail['new_value'].nil?
                    description += "\n\n **Parent issue: ##{rm_issue_conv[Integer(detail['new_value'])].iid}**"
                    create_note("#{redmine_text}Changed parent issue from ##{rm_issue_conv[Integer(detail['old_value'])].iid} to ##{rm_issue_conv[Integer(detail['new_value'])].iid}", convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                  else
                    create_note("#{redmine_text}Parent issue ##{rm_issue_conv[Integer(detail['old_value'])].iid} removed", convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                  end
                elsif !detail['new_value'].nil?
                  description += "\n\n **Parent issue: ##{rm_issue_conv[Integer(detail['new_value'])].iid}**"
                  create_note("#{redmine_text}Added parent issue ##{rm_issue_conv[Integer(detail['new_value'])].iid}", convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
                end
                gl_issue.description = description
              else
                messenger('journal_not_found', [detail['name']])
              end
            elsif CUSTOM_FEATURES.include? Integer(detail['name'])
              if detail['new_value']
                new << check_label(detail['new_value'], gl_project_id, true)
              end
              if detail['old_value']
                old << check_label(detail['old_value'], gl_project_id, true)
              end
            else
              messenger('journal_not_found', [journal.inspect])
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
                string = "Removed ~#{old[0]} label"
              end
            else
              if new.length > 1
                string = 'Added '
                new.each { |id| string << "~#{id} " }
                string << 'labels'
              else
                string = "Added ~#{new[0]} label"
              end
            end
            create_note(redmine_text+string, convert_user(journal['user']), journal['created_on'], gl_project_id, gl_issue.id)
          end
        end
      end

      unless rm_issue.status.nil?
        labels << check_label('Status: ' + Redmine::IssueStatus.find(rm_issue.status['id']).name, gl_project_id)
      end
      unless rm_issue.priority.nil?
        unless rm_issue.priority['name'].nil?
          labels << check_label('Priority: ' + rm_issue.priority['name'], gl_project_id)
        end
      end
      unless rm_issue.category.nil?
        unless rm_issue.category['name'].nil?
          labels << check_label(rm_issue.category['name'], gl_project_id, false, '#12AD2B')
        end
      end
      unless rm_issue.custom_fields.nil?
        rm_issue.custom_fields.each do | cf |
          if CUSTOM_FEATURES.include? Integer(cf['id'])
            if not cf['value'].nil? and not cf['value'].empty?
              labels << check_label(cf['value'], gl_project_id, false)
            end
          end
        end
      end
      unless rm_issue.tracker.nil?
        labels << check_label(rm_issue.tracker['name'], gl_project_id)
      end
      if !parent_changed && !rm_issue.parent.nil?
        description = gl_issue.description || ''
        description += "\n\n **Parent issue: ##{rm_issue_conv[Integer(rm_issue.parent['id'])].iid}**"
        gl_issue.description = description
      end
      messenger('new_labels', [labels, gl_issue.id])
      gl_issue.add_labels_by_names(labels)

      children = rm_issue.ls_children
      if children
        description = gl_issue.description || ''
        description += "\n#### Subtasks\n"
        description += "\n|    id    |   title  |   state  |"
        description += "\n| -------- | -------- | -------- |"
        children.each do |child|
          child_gl_issue = Issue.find(rm_issue_conv[Integer(child['id'])].id)
          description += "\n| ##{child_gl_issue.iid} | #{child_gl_issue.title} | #{child_gl_issue.state} |"
          gl_issue.description = description
        end
      end

      attachments = rm_issue.ls_attachments
      if attachments
        attachments.each do |attachment|
          uri = URI.parse(attachment['content_url'])
          filename = File.basename(uri.path)
          local_path = '/var/opt/gitlab/gitlab-rails/uploads/'
          project_path = User.find(gl_project.creator_id).name.downcase+'/'+gl_project.path
          IO.copy_stream(open('https://dev.snt.utwente.nl'+uri.path+'?key='+API_KEY), local_path+project_path+'/'+HASH+'/'+filename)
          filename.gsub! '%20', '_'
          url = 'http://' + Gitlab.config.gitlab.host + ':' + Gitlab.config.gitlab.port.to_s + '/' + project_path + "/uploads/#{HASH}/"+ filename
          redmine_text = ''
          if convert_user(attachment['author']) == DEFAULT_ACCOUNT
            redmine_text = "*#{attachment['author']['name']} (Redmine)*/n/n"
          end
          create_note("#{redmine_text}[#{filename}](#{url})", convert_user(attachment['author']), attachment['created_on'], gl_project_id, gl_issue.id, true, true)
        end
      end

      relations = rm_issue.ls_relations
      if relations
        description = gl_issue.description || ''
        description += "\n\n#### Related issues"
        description += "\n|    id    |   title  |   state  |"
        description += "\n| -------- | -------- | -------- |"
        relations.each do |relation|
          rel_gl_issue = Issue.find(rm_issue_conv[Integer(relation['issue_id'])].id)
          description += "\n| ##{rel_gl_issue.iid} | #{rel_gl_issue.title} | #{rel_gl_issue.state} |"
          gl_issue.description = description
        end
      end

      changesets = rm_issue.ls_changesets
      if changesets
        changesets.each do |changeset|
          redmine_text = ''
          if convert_user(changeset['user']) == DEFAULT_ACCOUNT
            redmine_text = "*#{changeset['user']['name']} (Redmine)*/n/n"
          end
          string = "#{redmine_text}mentioned in commit #{changeset['revision']}"
          create_note(string, convert_user(changeset['user']), changeset['committed_on'], gl_project_id, gl_issue.id)
        end
      end

      gl_issue.updated_at = rm_issue.updated_on

      unless gl_issue.save
        messenger('issue_errors', [gl_issue.errors.inspect])
      end
    end
    messenger('progress', ["--- #{rm_project.identifier} done"])
  else
    if PROJECT_CONVERSION.empty?
      messenger('not_found_project', [rm_project.identifier])
    else
      messenger('not_found_project', [rm_project])
    end
  end
end

