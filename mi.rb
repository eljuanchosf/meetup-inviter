# frozen_string_literal: true
require 'rubygems'
require 'bundler'
Bundler.require
require 'yaml'
require 'logger'
require 'capybara/dsl'
Dotenv.load

LOGGER = Logger.new(STDOUT)
LOGGER.level = Logger::DEBUG

CONFIG = YAML.load_file(File.join(Dir.pwd,'config.yml'))

display_pass = ENV['TM_PASS'].dup
display_pass[1..-1] = ('*' * (display_pass.size - 1))

FileUtils.mkdir_p(File.join(Dir.pwd, 'db'))
db_file = "sqlite://#{File.join(Dir.pwd, 'db', 'tm.db')}"
DB = Sequel.connect(db_file)
LOGGER.info('Starting Meetup Inviter...')
LOGGER.info("Database is: #{db_file}")
LOGGER.info("Username is: #{ENV['TM_USER']}")
LOGGER.info("Password is: #{display_pass}")

begin
  DB.create_table :users do
    Integer     :user_id
    String      :meetup_url
    String      :username
    String      :message_url
    Boolean     :sent,           default: false
    DateTime    :created_at,     default: DateTime.now
    primary_key [:user_id], :name=>:user_pk
  end
  LOGGER.info('Table created')
rescue Sequel::DatabaseError
  LOGGER.info('Table exists')
end

Capybara.run_server = false
Capybara.ignore_hidden_elements = false
Capybara.default_driver = :webkit

Capybara::Webkit.configure do |config|
  # Enable debug mode. Prints a log of everything the driver is doing.
  config.debug = false
  # Allow pages to make requests to any URL without issuing a warning.
  config.allow_unknown_urls
  # Allow a specific domain without issuing a warning.
  config.allow_url('meetup.com/*')
  # Don't raise errors when SSL certificates can't be validated
  config.ignore_ssl_errors
end

class Mi < Thor
  include Capybara::DSL

  desc 'populate', 'Populates the database'
  long_desc <<-LONGDESC
    `mi populate` will scan #{CONFIG['start_url']} and get the list of videos
    to download into a database.
  LONGDESC
  def populate
    start_crawl
    CONFIG['meetups'].each do |meetup_url|
      crawl_meetup_users(meetup_url)
    end
    LOGGER.info('Finished populating!')
  end

  desc 'send', 'Download the videos'
  long_desc <<-LONGDESC
    `mi download` will send the message to the users
  LONGDESC
  def send
    LOGGER.info "Message is:\n#{CONFIG['message']}"
    LOGGER.info "Sending #{DB[:users].count} messages"
    users = DB[:users].where('sent = ?', false)
    start_crawl
    users.each do |user|
      send_message(user)
    end
    LOGGER.info('Finished sending!')
  end

  desc 'full_crawl', 'Prepopulate and download videos'
  long_desc <<-LONGDESC
    `mi full_crawl` will prepopulate the database and download the videos from
    the list into #{ENV['TARGET_FOLDER']}
  LONGDESC
  def full_crawl
    populate
    send
  end

  private

  def start_crawl
    login(CONFIG['start_url'])
    sleep 2
  end

  def login(url)
    visit(url)
    fill_in('email', with: ENV['TM_USER'])
    fill_in('password', with: ENV['TM_PASS'])
    find(:xpath, "//*[@id='loginForm']/div/div[3]/input").trigger('click')
  end

  def send_message(user)
    first_name = user[:username].split(' ').first
    message = CONFIG['message'].gsub('username', first_name)
    LOGGER.info "Sending message to #{user[:username]}"
    visit(user[:message_url])
    doc = Nokogiri::HTML(page.html)
    begin
      while find(:css, "i.icon-refresh.spinning", visible: true)
        sleep 1
      end
    rescue Capybara::ElementNotFound
      fill_in('messaging-new-convo', with: message)
      find_by_id('messaging-new-send',wait: 5).trigger('click')
      DB[:users].where('user_id = ?', user[:user_id]).update(sent: true)
      LOGGER.info "Message sent!"
      sleep rand(3..5)
    end
  end

  def message_url(username, user_id)
    "https://secure.meetup.com/es-ES/messages/?new_convo=true&amp;member_id=#{user_id}&amp;name=#{username}"
  end

  def user_list_url(page, meetup_url)
    offset = (page * 20) - 20
    "#{meetup_url}/members/?offset=#{offset}&sort=name&desc=0"
  end

  def pages(total_members)
    upp = CONFIG['users_per_page'].to_i
    pages = (total_members / upp)
    if (total_members % upp) > 0
      pages += 1
    end
    pages
  end

  def add_meetup_users(meetup_users, meetup_url)
    meetup_users.each do |meetup_user|
      user_id = meetup_user.attr('data-memid').strip
      username = meetup_user.xpath("div/div[2]/h4/a").text.strip
      user = { meetup_url: meetup_url,
               username:   username,
               user_id:    user_id,
               message_url: message_url(username, user_id)
             }
      if DB[:users].where(user_id: user_id).count == 0
        DB[:users].insert(user)
        LOGGER.info "Added user #{username} - #{user_id}"
      end
    end
  end

  def crawl_meetup_users(meetup_url)
    visit(meetup_url)
    find(:xpath, "//*[@id='group-links']/li[2]/a").trigger('click')
    doc = Nokogiri::HTML(page.html)
    total_members = doc.xpath("//*[@id='C_document']/div/div[2]/ul/li[1]/a/span").text.strip.delete('()').to_i
    1.upto(pages(total_members)) do |page_number|
      LOGGER.info "Visiting #{user_list_url(page_number, meetup_url)}"
      visit(user_list_url(page_number, meetup_url))
      doc = Nokogiri::HTML(page.html)
      add_meetup_users(doc.xpath("//*[@id='memberList']/li"), meetup_url)
    end
  end
end

Mi.start
