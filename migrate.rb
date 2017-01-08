#!/usr/bin/env ruby

require 'fileutils'
require 'gitlab'
require_relative 'redmine'
require_relative 'config'

NilClass.class_eval <<EOC
def name
  nil
end

def id
  nil
end
EOC

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
  return if title.nil?
  label = Label.find_by_title(title)
  if label.nil?
    new_label = Label.new
    new_label.project_id = gl_project_id
    new_label.title = title.gsub ',', ';'
    if color
      new_label.color = color
    end
    new_label.save!
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
  new_note.author_id = author || DEFAULT_ACCOUNT
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
    gl_project = Project.find_with_namespace(rm_p[1])
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
        gl_user_id = convert_user(rm_user) || DEFAULT_ACCOUNT

        if OPEN_VALUES.include? issue.status['name']
          state = 'opened'
        else
          state = 'closed'
        end
        issue.inspect
        new_issue = Issue.new
        new_issue.title = issue.subject
        new_issue.iid = issue.send(COPY_ISSUE_ID_FIELD) unless COPY_ISSUE_ID_FIELD.nil?
        new_issue.state = state

        new_issue.author_id = gl_user_id
        new_issue.project_id = gl_project_id
        new_issue.created_at = issue.created_on

        description = issue.description
        description.gsub! '\r\n', '\n\n'
        description.gsub! '<pre>', '```'
        description.gsub! '</pre>', '```'
        description += "\n\n *Originally created by #{rm_user.firstname} #{rm_user.lastname} (Redmine)*" if gl_user_id == DEFAULT_ACCOUNT
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
          messenger('issue_errors', new_issue.errors.inspect)
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
          redmine_text = "*#{journal['user']['name']} (Redmine)*\n\n"
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
                unless detail['new_value'].nil? or detail['new_value'].empty?
                  new << check_label('Status: ' + Redmine::IssueStatus.find(detail['new_value']).name, gl_project_id, true)
                end
                unless detail['old_value'].nil? or detail['old_value'].empty?
                  old << check_label('Status: ' + Redmine::IssueStatus.find(detail['old_value']).name, gl_project_id, true)
                end
                if CLOSED_VALUES.include? detail['new_value'] and OPEN_VALUES.include? detail['old_value']
                  create_event(gl_issue, convert_user(journal['user']), Event::CLOSED, journal['created_on'])
                elsif OPEN_VALUES.include? detail['new_value'] and CLOSED_VALUES.include? detail['old_value']
                  create_event(gl_issue, convert_user(journal['user']), Event::REOPENED, journal['created_on'])
                end
              elsif detail['name'] == 'priority_id'
                unless detail['new_value'].nil? or detail['new_value'].empty?
                  new << check_label('Priority: ' + PRIORITIES[Integer(detail['new_value'])], gl_project_id, true)
                end
                unless detail['old_value'].nil? or detail['old_value'].empty?
                  old << check_label('Priority: ' + PRIORITIES[Integer(detail['old_value'])], gl_project_id, true)
                end
              elsif detail['name'] == 'assigned_to_id'
                unless detail['old_value'].nil? or detail['old_value'].empty?
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
                unless detail['new_value'].nil? or detail['new_value'].empty?
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
                unless detail['new_value'].nil? or detail['new_value'].empty?
                  new << check_label(Redmine::IssueCategory.find(detail['new_value'].to_i).name, gl_project_id, true, '#12AD2B')
                end
                unless detail['old_value'].nil? or detail['old_value'].empty?
		  ic = Redmine::IssueCategory.find(detail['old_value'].to_i)
                  old << check_label(ic.name, gl_project_id, true, '#12AD2B') unless ic.nil? or ic.name.empty?
                end
              elsif detail['name'] == 'tracker_id'
                tracker_changed = true
                unless detail['new_value'].nil? or detail['new_value'].empty?
                  new << check_label(Redmine::Tracker.find(detail['new_value'].to_i).name, gl_project_id, true)
                end
                unless detail['old_value'].nil? or detail['old_value'].empty?
                  old << check_label(Redmine::Tracker.find(detail['old_value'].to_i).name, gl_project_id, true)
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
              unless detail['new_value'].nil? or detail['new_value'].empty?
                new << check_label(detail['new_value'], gl_project_id, true)
              end
              unless detail['old_value'].nil? or detail['old_value'].empty?
                old << check_label(detail['old_value'], gl_project_id, true)
              end
            else
              messenger('journal_not_found', [journal.inspect])
            end
          end

	  old.compact!
	  new.compact!
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
	cfg = Gitlab.config.gitlab
	project_path = gl_project.path_with_namespace
	upload_path = File.join(UPLOADS_PATH, project_path, HASH)
	FileUtils.mkdir_p(upload_path)

        attachments.each do |attachment|
          uri = URI.parse(attachment['content_url'])
          filename = File.basename(uri.path).gsub '%20', '_'
          IO.copy_stream(open("#{attachment['content_url']}?key=#{API_KEY}"), File.join(upload_path, filename))
          url = "http#{'s' if cfg.https}://#{cfg.host}#{":#{cfg.port}" unless cfg.https and cfg.port == 443 or cfg.port == 80}/#{project_path}/uploads/#{HASH}/#{filename}"
          redmine_text = ''
          if convert_user(attachment['author']) == DEFAULT_ACCOUNT
            redmine_text = "*#{attachment['author']['name']} (Redmine)*\n\n"
          end
          create_note("#{redmine_text}[#{filename}](#{url})", convert_user(attachment['author']), attachment['created_on'], gl_project_id, gl_issue.id, true, true)
        end
      end


      changesets = rm_issue.ls_changesets
      if changesets
        changesets.each do |changeset|
          redmine_text = ''
          if convert_user(changeset['user']) == DEFAULT_ACCOUNT
            redmine_text = "*#{changeset['user']['name']} (Redmine)*\n\n"
          end
          string = "#{redmine_text}mentioned in commit #{changeset['revision']}"
          create_note(string, convert_user(changeset['user']), changeset['committed_on'], gl_project_id, gl_issue.id)
        end
      end

      gl_issue.updated_at = rm_issue.updated_on

      unless gl_issue.save
        messenger('issue_errors', gl_issue.errors.inspect)
      end
    end

    rm_issue_conv.each do |rm_issue_id, gl_issue|
      rm_issue = Redmine::Issue.find(rm_issue_id)
      relations = rm_issue.ls_relations
      if relations
        description = gl_issue.description || ''
        description += "\n\n#### Related issues"
        description += "\n|    id    |   title  |   state  |"
        description += "\n| -------- | -------- | -------- |"
        relations.each do |relation|
          description += "\n| ##{gl_issue.iid} | #{gl_issue.title} | #{gl_issue.state} |"
          gl_issue.description = description
        end

	messenger('issue_errors', gl_issue.errors.inspect) unless gl_issue.save
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

