# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Ruby script that generates daily standup messages from Notion databases, formatted for Slack. It's a single-file application (`standup.rb`) that queries two Notion databases (daily standup items and song of the day) and formats them into a structured standup message.

## Running the Script

```bash
ruby standup.rb
```

This outputs the formatted standup text to stdout, ready to be copied and pasted into Slack.

## Setup and Configuration

### Installing Dependencies

```bash
bundle install
```

### Environment Configuration

Copy `.env.sample` to `.env` and configure:
- `NOTION_API_TOKEN`: Notion integration API token
- `STANDUP_DATABASE_ID`: ID of the daily standup database
- `SOTD_DATABASE_ID`: ID of the song of the day database
- `SOTD_PLAYLIST_URL`: Spotify playlist URL for song of the day
- `JIRA_PROJECT_ID`: Jira project prefix (e.g., "ABC" for ABC-1234 issues)
- `JIRA_PROJECT_URL`: Base URL for Jira issue links
- `GITHUB_CONFIG_FILE`: Path to GitHub configuration JSON

The script also supports Azure DevOps work items via `ADO_PROJECT_IDS` and `ADO_PROJECT_URLS` environment variables.

## Architecture

### Core Class: DailyStandup

The `DailyStandup` class is the main component that:
1. Fetches records from Notion databases via the `notion-ruby-client` gem
2. Categorizes items into sections: Previous, Today, Blockers, Gratitude, and Song of the Day
3. Applies Mustache templating and link replacement
4. Outputs formatted text

### Notion Database Requirements

**Daily Standup Database** must have:
- `Item Date` (formula): Calculates the effective date, with support for `Override Date`
- `Name` (title): The standup item text
- `Category` (select): Options are `Normal`, `Gratitude`, `Blocker`
- `Completed` (checkbox): Whether the item is done
- `Override Date` (date): Optional override for the item date
- `IsPrevious` (formula): Determines if item belongs to previous business day

**Song of the Day Database** must have:
- `Song Title` (title)
- `Artist` (text)
- `URL` (url)
- `Notes` (text)
- `Created time` (created time)
- `CurrentSong` (formula): `prop("Created time").formatDate("YYYY-MM-DD") == now().formatDate("YYYY-MM-DD")`

### Business Day Logic

The script handles weekends in `previous_business_day` method:
- If today is Monday, "previous day" is Friday
- Otherwise, it's the previous calendar day (skipping weekends)

### Template Variables

Notion database text fields support Mustache templates with these variables:
- `{{day_of_week}}`: Current day name (e.g., "Tuesday")
- `{{fortune}}`: Random wisdom fortune (uses `fortune` command if installed, otherwise fallback quotes)
- `{{sotd}}`: Current song of the day (auto-generated from SOTD database)
- `{{dadjoke}}`: Random dad joke from icanhasdadjoke.com API

### Link Replacement

The script automatically converts:
- Jira issue IDs (e.g., `ABC-1234`) into markdown links
- Azure DevOps work item IDs into markdown links

### Sorting Behavior

Items are sorted by:
1. `Item Date` formula string (primary)
2. `created_time` field (secondary)

This ensures chronological ordering within each section.

## Ruby Version

This project uses Ruby 3.2.2 (specified in `.ruby-version`).

## Key Dependencies

- `notion-ruby-client`: Notion API client
- `mustache`: Template rendering
- `dotenv`: Environment variable loading
- `rest-client`: HTTP client for external APIs (dad jokes)
- `debug`: Ruby debugging support
- `shellwords`: Prevent injection when running shell commands
