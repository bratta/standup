# frozen_string_literal: true

require 'date'
require 'debug'
require 'dotenv/load'
require 'json'
require 'mustache'
require 'notion-ruby-client'
require 'rest-client'
require 'shellwords'

# Database assumptions
# Main standup database parameters:
#   Item Date (formula: formatDate(if(empty(prop("Override Date")), prop("Created Time"), prop("Override Date")), "YYYY/MM/DD")),
#   Name (title),
#   Category (select with options: Normal, Gratitude, Blocker)
#   Completed (checkbox)
#   Override Date (date)
#   IsPrevious (formula: now().dateSubtract(if(now().dateSubtract(1, "days").day() > 5, 3, 1), "days").formatDate("YYYY/MM/DD") == prop("Item Date"))
#
# Song of the day database parameters:
#   Song Title (title)
#   Artist (text)
#   URL (url)
#   Notes (text)
#   Created time
#   CurrentSong (formula: prop("Created time").formatDate("YYYY-MM-DD") == now().formatDate("YYYY-MM-DD"))
#
# For fun: Install fortune: `brew install fortune`
#
# Templates: You can use mustache templates in your database. Try using these:
#   {{day_of_week}} - Current day of the week (e.g. "Tuesday")
#   {{fortune}} - A random fortune from the above application (currently the "wisdom" file)
#   {{dadjoke}} - Calls the icanhasdadjoke API for a random dad joke
# See the `template_variables` method for more

# Daily Standup class
class DailyStandup
  attr_accessor :records, :sotd_records, :sections, :categories, :template

  # Constructor
  def initialize
    @sections = {
      previous: 'Previous',
      today: 'Today',
      blockers: 'Blockers',
      gratitude: 'Gratitude/Joy/Others',
      sotd: 'Song of the Day'
    }
    @records = fetch_database(ENV['STANDUP_DATABASE_ID'])
    @sotd_records = fetch_database(ENV['SOTD_DATABASE_ID'])
    @template = template_variables
  end

  # Load the Notion database, by database ID.
  def fetch_database(database_id)
    [].tap do |records|
      client = Notion::Client.new(token: ENV['NOTION_API_TOKEN'])
      client.database_query(database_id:) do |db|
        db.results.each do |row|
          records.push(row)
        end
      end
    end
  end

  # This builds up each section, based on section name and category.
  # For example, `section_for_categories(:today, :Normal)`
  # Will load all the entries for the current day with the "Normal" category, using the proper
  # header text for the section.
  def section_for_categories(section, category)
    result = "*#{@sections[section]}:*\n"
    items = []
    current_records = @records.select { |r| r.dig(:properties, :Category, :select, :name)&.to_sym == category }
      .sort do |a, b|
        a.dig(:properties, :"Item Date", :formula, :string) && b.dig(:properties, :"Item Date", :formula, :string) &&
        Date.parse(a.dig(:properties, :"Item Date", :formula, :string)) <=> Date.parse(b.dig(:properties, :"Item Date", :formula, :string))
      end
      .sort do |a, b|
        a.created_time && b.created_time &&
        Date.parse(a.created_time) <=> Date.parse(b.created_time)
      end

    current_records.each do |record|
      case section
      when :previous
        items.concat(previous_entries(record))
      when :today
        items.concat(todays_entries(record))
      when :blockers
        items.concat(blocker_entries(record))
      when :gratitude
        items.concat(gratitude_entries(record))
      end
    end

    items.push("* None\n") if items.empty?
    result += items.join('')
    render(result)
  end

  # Previous day's entries
  def previous_entries(record)
    [].tap do |items|
      date = previous_business_day
      item_date = record.dig(:properties, :"Item Date", :formula, :string)
      if item_date && Date.parse(item_date) == date &&
         record.dig(:properties, :Completed, :checkbox) == false
        items.push("* #{title_string(record)}\n")
      end
    end
  end

  # Blocker entries
  def blocker_entries(record)
    [].tap do |items|
      items.push("* #{title_string(record)}\n") if record.dig(:properties, :Completed, :checkbox) == false
    end
  end

  # Today's entries
  def todays_entries(record)
    [].tap do |items|
      date = Date.today
      item_date = record.dig(:properties, :"Item Date", :formula, :string)
      if item_date && Date.parse(item_date) == date &&
         record.dig(:properties, :Completed, :checkbox) == false
        items.push("* #{title_string(record)}\n")
      end
    end
  end

  # Gratitude entries
  def gratitude_entries(record)
    [].tap do |items|
      items.push("* #{title_string(record)}\n") if record.dig(:properties, :Completed, :checkbox) == false
    end
  end

  # Notion stores its titles in an odd way. This ensures they show up decently.
  def title_string(record)
    record.dig(:properties, :Name, :title).map(&:plain_text).join('')
  end

  # Calculate the previous day, but keep business days in mind.
  # If today is Monday, the previous day will be Friday.
  def previous_business_day
    date = Date.today
    date -= 1
    # 0 = Sunday, 6 = Saturday
    date -= 1 while date.wday.zero? || date.wday == 6
    date
  end

  # Parse the "Song of the Day" database and format the most recent entry.
  def current_song_of_the_day
    result = "[#{@sections[:sotd]}](#{ENV['SOTD_PLAYLIST_URL']}): "
    sotd = @sotd_records
           .sort do |a, b|
             a.created_time && b.created_time &&
               Date.parse(b.created_time) <=> Date.parse(a.created_time)
           end
           .select { |r| r.dig(:properties, :CurrentSong, :formula, :boolean) == true }.first

    if sotd
      url = sotd.dig(:properties, :URL, :url)
      artist = sotd.dig(:properties, :Artist, :rich_text).map(&:plain_text).join('')
      title = sotd.dig(:properties, :"Song Title", :title).map(&:plain_text).join('')
      notes = sotd.dig(:properties, :Notes, :rich_text).map(&:plain_text).join('')
      notes = " - #{notes}" if notes && !notes.strip.empty?
      result += ":musical_note: [#{artist} - #{title}](#{url}) :musical_note:#{notes}"
    else
      result += "None"
    end
    result
  end

  # This method loads a list of open pull requests from Github
  # using the gh command line, and outputs the formatted list
  def build_github_pull_request_section
    config_file = ENV['GITHUB_CONFIG_FILE']
    return nil unless config_file && File.exist?(config_file)

    config = JSON.parse(File.read(config_file))
    github_user = config['user']

    items = config['projects'].flat_map do |project|
      output = `gh pr list --author #{Shellwords.escape(github_user)} -R #{Shellwords.escape(project['project_name'])} --json url,title`
      JSON.parse(output).map do |pr|
        "* #{project['display_name']}: [#{pr['title']}](#{pr['url']})\n"
      end
    end

    return nil if items.empty?

    "*Open Pull Requests:*\n#{items.join('')}"
  end

  # This will turn text like PLS-1234 into a linkified version.
  def replace_jira_links(text)
    ENV['JIRA_PROJECT_IDS'].split(/,/).each do |project_id|
      text = text.gsub(/(#{project_id}-\d+)/, "[\\1](#{ENV['JIRA_PROJECT_URL']}\\1)")
    end
    return text
  end

  def replace_ado_links(text)
    project_ids = ENV['ADO_PROJECT_IDS'].split(/,/)
    project_urls = ENV['ADO_PROJECT_URLS'].split(/;/)
    if project_ids.count != project_urls.count
      raise "ADO project ID names and URL values do not match up."
    end
    project_ids.each_with_index do |id, idx|
      url = project_urls[idx]
      text = text.gsub(/#{id}[^\d]?(\d+)/, "[#{id} \\1](#{url}?workitem=\\1)")
    end
    return text
  end

  # Render the mustache templates, plus any internal text replacement.
  def render(text)
    Mustache.render(replace_ado_links(replace_jira_links(text)), @template)
  end

  # Here are the defined variables. Inside your notion texts, you can use things like
  # {{day_of_week}} to replace it with the contents you see here.
  def template_variables
    {
      day_of_week: Date.today.strftime('%A'),
      fortune: random_fortune,
      sotd: current_song_of_the_day,
      dadjoke: i_can_has_dadjoke
    }
  end

  # This is just for fun. Add a little quote/fortune to your standup if you'd like.
  def random_fortune
    if which('fortune')
      `fortune -s wisdom`.strip.gsub("\n", ' ').gsub("\t", '  ').gsub("\r", ' ')
    else
      [
        'You must make your own fortune',
        'Fortune favors the prepared mind. -- Louis Pasteur',
        'Fortune always favors the brave, and never helps a man who does not help himself -- PT Barnum',
        'Any fool can write code that a computer can understand. ' \
          'Good programmers write code that humans can understand. -- Martin Fowler'
      ].sample
    end
  end

  def i_can_has_dadjoke
    uri = 'https://icanhasdadjoke.com'
    response = RestClient.get uri, {accept: :json}
    raise  Exception.new "Response #{response.code} received from #{uri}" if response.code != 200
    return JSON.parse(response.body)['joke']
  end

  # Utility method to determine if the current user has a command available in the path.
  def which(cmd)
    exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
    ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
      exts.each do |ext|
        exe = File.join(path, "#{cmd}#{ext}")
        return exe if File.executable?(exe) && !File.directory?(exe)
      end
    end
    nil
  end
end

# Disable HTML escaping
class Mustache
  def escapeHTML(str)
    str
  end
end

standup = DailyStandup.new
puts standup.section_for_categories(:previous, :Normal)
puts standup.section_for_categories(:today, :Normal)
puts standup.section_for_categories(:blockers, :Blocker)
puts standup.build_github_pull_request_section()
puts standup.section_for_categories(:gratitude, :Gratitude)
