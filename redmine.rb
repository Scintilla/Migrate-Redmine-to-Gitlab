require 'faraday'
require 'json'

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
    return nil if result.status >= 400
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
      return nil if list.nil?

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
      return nil if response.nil?
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
