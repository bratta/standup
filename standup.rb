# frozen_string_literal: true

require 'date'
require 'debug'
require 'dotenv/load'
require 'mustache'
require 'notion-ruby-client'

# Database assumptions
# Main standup database parameters:
#   Item Date (date),
#   Name (title),
#   Category (select with options: Normal, Gratitude, Blocker)
#   Completed (checkbox)
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
# See the `template_variables` method for more

class DailyStandup
  attr_accessor :records, :sotd_records, :sections, :categories, :template

  # Constructor
  def initialize
    @sections = {
      previous: "Previous",
      today: "Today",
      blockers: "Blockers",
      gratitude: "Gratitude/Joy/Others",
      sotd: "Song of the Day"
    }
    @records = fetch_database(ENV['STANDUP_DATABASE_ID'])
    @sotd_records = fetch_database(ENV['SOTD_DATABASE_ID'])
    @template = template_variables
  end

  # Load the Notion database, by database ID.
  def fetch_database(database_id)
    [].tap do |records|
      client = Notion::Client.new(token: ENV['NOTION_API_TOKEN'])
      client.database_query(database_id: database_id) do |db|
        db.results.each do |row|
          records.push(row)
        end
      end
    end
  end

  # This builds up each section, based on section name and category.
  # For example, `get_section_for_categories(:today, :Normal)`
  # Will load all the entries for the current day with the "Normal" category, using the proper
  # header text for the section.
  def get_section_for_categories(section, category)
    result = "*#{@sections[section]}:*\n"
    items = []
    @records.select {|r| r.dig(:properties, :Category, :select, :name)&.to_sym == category }
      .sort { |a, b| a.created_time && b.created_time && Date.parse(a.created_time) <=> Date.parse(b.created_time) }
      .each do |record|
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
    items.push("* None\n") if items.length == 0
    result += items.join('')
    render(result)
  end

  # Previous day's entries
  def previous_entries(record)
    [].tap do |items|
      date = get_previous_business_day
      item_date = record.dig(:properties, :"Item Date", :date, :start)
      if item_date && Date.parse(item_date) == date &&
        record.dig(:properties, :Completed, :checkbox) == false
          items.push("* #{get_title_string(record)}\n")
      end
    end
  end

  def blocker_entries(record)
    [].tap do |items|
      if record.dig(:properties, :Completed, :checkbox) == false
        items.push("* #{get_title_string(record)}\n")
      end
    end
  end

  # Today's entries
  def todays_entries(record)
    [].tap do |items|
      date = get_current_day
      item_date = record.dig(:properties, :"Item Date", :date, :start)
      if item_date && Date.parse(item_date) == date &&
        record.dig(:properties, :Completed, :checkbox) == false
          items.push("* #{get_title_string(record)}\n")
      end
    end
  end

  # Gratitude entries
  def gratitude_entries(record)
    [].tap do |items|
      if record.dig(:properties, :Completed, :checkbox) == false
        items.push("* #{get_title_string(record)}\n")
      end
    end
  end

  # Notion stores its titles in an odd way. This ensures they show up decently.
  def get_title_string(record)
    record.dig(:properties, :Name, :title).map {|t| t.plain_text }.join('')
  end

  # Yeah, this is dumb. Done to be consistent with the previous day
  def get_current_day
    Date.today
  end

  # Calculate the previous day, but keep business days in mind.
  # If today is Monday, the previous day will be Friday.
  def get_previous_business_day
    date = Date.today
    date -= 1
    # 0 = Sunday, 6 = Saturday
    while date.wday == 0 || date.wday == 6
      date -= 1
    end
    date
  end

  # Parse the "Song of the Day" database and format the most recent entry.
  def get_current_song_of_the_day
    result = "* [#{@sections[:sotd]}](#{ENV['SOTD_PLAYLIST_URL']}): "
    sotd = @sotd_records
      .sort { |a, b| a.created_time && b.created_time && Date.parse(b.created_time) <=> Date.parse(a.created_time) }
      .select {|r| r.dig(:properties, :CurrentSong, :formula, :boolean) == true }.first
    if sotd
      url = sotd.dig(:properties, :URL, :url)
      artist = sotd.dig(:properties, :Artist, :rich_text).map {|a| a.plain_text }.join('')
      title = sotd.dig(:properties, :"Song Title", :title).map {|a| a.plain_text }.join('')
      notes = sotd.dig(:properties, :Notes, :rich_text).map {|a| a.plain_text }.join('')
      notes = " - #{notes}" if notes && !notes.strip.empty?
      result += ":musical_note: [#{artist} - #{title}](#{url}) :musical_note:#{notes}\n";
    else
      result += "None\n";
    end
    result
  end

  # This will turn text like PLS-1234 into a linkified version.
  def replace_jira_links(text)
    text.gsub(/(#{ENV['JIRA_PROJECT_ID']}-[\d]+)/, "[\\1](#{ENV['JIRA_PROJECT_URL']}\\1)")
  end

  # Render the mustache templates, plus any internal text replacement.
  def render(text)
    Mustache.render(replace_jira_links(text), @template)
  end

  # Here are the defined variables. Inside your notion texts, you can use things like
  # {{day_of_week}} to replace it with the contents you see here.
  def template_variables
    {
      day_of_week: Date.today.strftime('%A'),
      fortune: random_fortune
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
        'Any fool can write code that a computer can understand. Good programmers write code that humans can understand. -- Martin Fowler'
      ].sample
    end
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
puts standup.get_section_for_categories(:previous, :Normal)
puts standup.get_section_for_categories(:today, :Normal)
puts standup.get_section_for_categories(:blockers, :Blocker)
puts standup.get_section_for_categories(:gratitude, :Gratitude)
puts standup.get_current_song_of_the_day
