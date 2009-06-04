#!/usr/bin/ruby

# Chart generator class of bouncer statistics.
# Copyright (C) 2009 Takashi Nakamoto.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require './conf.rb'

require 'sqlite3'
require 'cgi'

class KnownException < Exception; end

class ChartGenerator
  ###################################################
  # Initialization.
  ###################################################
  def initialize(dbfile, tblname)
    @db = SQLite3::Database.new(dbfile)
    @tbl = tblname
    @cgi = CGI.new("html4")

    check_argument
  end

  ###################################################
  # Getting arguments and checking the validity.
  ###################################################
  def check_argument
    # Dates:
    #  This CGI generates a chart based on the data generated between
    #  these days.
    @start_date = Date.new(@cgi['start_year'].to_i,
                           @cgi['start_month'].to_i,
                           @cgi['start_day'].to_i)
    @end_date = Date.new(@cgi['end_year'].to_i,
                         @cgi['end_month'].to_i,
                         @cgi['end_day'].to_i)

    if @start_date > @end_date
      tmp = @start_date
      @start_date = @end_date
      @end_date = tmp
    end

    res = @db.execute("SELECT MIN(datejd) FROM #{$tblname}")
    first_date = Date.jd(res[0][0].to_i)

    res = @db.execute("SELECT MAX(datejd) FROM #{$tblname}")
    last_date = Date.jd(res[0][0].to_i)

    if @start_date < first_date
      raise KnownException,
      "you specified the date before #{first_date.strftime('%Y-%m-%d')}."
    elsif @end_date > last_date
      raise KnownException,
      "you specified the date after #{last_date.strftime('%Y-%m-%d')}."
    end

    # Products:
    #  This CGI generates a chart based on the data related to the
    #  specified product name like "OpenOffice.org". If there is
    #  "product=ALL", or if there is no arguments related to
    #  product, then all products will be selected for the chart
    #  data.
    @products = @cgi.params['product']
    @products = :all if @products.empty? || @products.include?("ALL")

    # Languagess:
    #  This CGI generates a chart based on the data related to the
    #  specified language name like "en-us". If there is "language=ALL",
    #  or if there is no arguments related to language, then all
    #  languages will be selected for the chart data.
    @languages = @cgi.params['language']
    @languages = :all if @languages.empty? || @languages.include?("ALL")

    # OS:
    #  This CGI generates a chart based on the data related to the
    #  specified the name of OS and architectures like "winwjre".
    #  If there is "os=ALL", or if there is no arguments related to
    #  OS, then all OSes will be selected for the chart data.
    @oses = @cgi.params['os']
    @oses = :all if @oses.empty? || @oses.include?("ALL")

    # Type of chart:
    #  This CGI generates a specified type of chart.
    @type = @cgi['type']
    if !$valid_types.include?(@type)
      raise KnownException, "Invalid argument for 'type': #{@type}"
    end
  end

  ###################################################
  # Generating SQL statement.
  ###################################################
  def sql_statement
    where_conds = "WHERE "

    # Conditions for products, languages and oses.
    { "product" => @products,
      "language" => @languages,
      "os" => @oses }.each{ |name, set|

      # Note that "set" cannot be empty here.
      # See the part of checking arguments.
      if set != :all # || set.empty?
        where_conds += "#{name} IN ("
        set.each{ |e| where_conds += "'#{e}', " }
        where_conds[-2] = ")"
        where_conds += "AND "
      end
    }

    # Conditions for date
    where_conds += "datejd>=#{@start_date.jd} AND datejd<=#{@end_date.jd} "

    sql = ""

    if @type == "pie_by_product"
      sql += "SELECT product, Sum(downloads) AS 'count' FROM #{@tbl} "
      sql += where_conds
      sql += "GROUP BY product "
      sql += "ORDER BY product "
    elsif @type == "pie_by_language"
      sql += "SELECT language, Sum(downloads) AS 'count' FROM #{@tbl} "
      sql += where_conds
      sql += "GROUP BY language "
      sql += "ORDER BY language "
    elsif @type == "pie_by_oswa" || @type == "pie_by_os"
      sql += "SELECT os, Sum(downloads) AS 'count' FROM #{@tbl} "
      sql += where_conds
      sql += "GROUP BY os "
      sql += "ORDER BY os "
    elsif @type == "line_by_product"
      sql += "SELECT datejd, product, Sum(downloads) FROM #{@tbl} "
      sql += where_conds
      sql += "GROUP BY datejd, product "
      sql += "ORDER BY product, datejd ASC "
    elsif @type == "line_by_language"
      sql += "SELECT datejd, language, Sum(downloads) FROM #{@tbl} "
      sql += where_conds
      sql += "GROUP BY datejd, language "
      sql += "ORDER BY language, datejd ASC "
    elsif @type == "line_by_oswa" || @type == "line_by_os"
      sql += "SELECT datejd, os, Sum(downloads) FROM #{@tbl} "
      sql += where_conds
      sql += "GROUP BY datejd, os "
      sql += "ORDER BY os, datejd ASC "
    elsif @type == "count"
      sql += "SELECT Sum(downloads) as 'count' FROM #{@tbl} "
      sql += where_conds
    end

    sql
  end

  ###################################################
  # Fetching data from database.
  ###################################################
  def select(sql)
    STDERR.puts sql # for debug purpose
    @db.execute(sql)
  end

  ########################################################
  # Generate a chart and return SVG or HTML as a result
  ########################################################
  def generate
    # fetching data
    res = select(sql_statement)

    output = ""

    if @type == "count"
      output = @cgi.out('charset'=>$charset) {
        html = @cgi.html { 
          @cgi.head { @cgi.title{'OpenOffice.org Bouncer statistics'} } +
          @cgi.body { 
            res[0][0].to_i
          }
        }

        CGI.pretty(html)
      }
    elsif @type =~ /^pie/
      fields = []
      values = []

      if @type == "pie_by_os" # Special manipulation for this type of chart.
        # Group by OS name
        h = {}
        res.each{ |r|
          case r[0]
          when /^win/
            h["Windows"] = 0 unless h["Windows"]
            h["Windows"] += r[1].to_i
          when /^linux/
            h["Linux"] = 0 unless h["Linux"]
            h["Linux"] += r[1].to_i
          when /^macosx/
            h["Mac OS X"] = 0 unless h["Mac OS X"]
            h["Mac OS X"] += r[1].to_i
          when /^solaris/
            h["Solaris"] = 0 unless h["Solaris"]
            h["Solaris"] += r[1].to_i
          else
            h["Others"] = 0 unless h["Others"]
            h["Others"] += r[1].to_i
          end      
        }

        # Show the chart in this order.
        ["Windows", "Linux", "Mac OS X", "Solaris", "Others"].each{ |os_name|
          fields << os_name
          values << h[os_name]
        }
      else
        res.each{ |r|
          fields << r[0]
          values << r[1].to_i
        }
      end

      # Generate SVG chart
      require 'SVG/Graph/Pie'
      graph = SVG::Graph::Pie.new({ :height => 500,
                                    :width => 900,
                                    :fields => fields,
                                    :scale_x_integers => true,
                                    :min_x_value => 0,
                                    :min_y_value => 0,
                                    :show_data_labels => false,
                                    :x_title => "Date",
                                    :show_x_title => true,
                                    :y_title => "Download counts a day",
                                    :show_y_title => true, })
      graph.min_x_value = 0
      graph.min_y_value = 0

      graph.add_data({ :data => values,
                       :title => 'Bouncer Statistics'})

      output << "Content-type: image/svg+xml\r\n\r\n"
      output << graph.burn()
    elsif @type =~ /^line/
      # set x label
      fields = []
      date = @start_date
      interval = ((@end_date - @start_date) / 10).round
      while date <= @end_date
        if (date - @start_date) % interval == 0 
          fields << date.strftime("%Y/%m/%d")
        else
          fields << ""
        end
        date += 1
      end

      # set data
      lines = {}
      max_value = 0
      res.each{ |r|
        lines[r[1]] = Array.new(fields.size, 0) if lines[r[1]] == nil

        date = Date.jd(r[0].to_i)
        i = date - @start_date
        lines[r[1]][i] = r[2].to_i

        max_value = r[2].to_i if r[2].to_i > max_value
      }

      # TODO: change the scale (might be needed to change SVG::Graph library)

      require 'SVG/Graph/Line'
      graph = SVG::Graph::Line.new({ :height => 500,
                                     :width => 850,
                                     :fields => fields,
                                     :min_scale_value => 0,
                                     :show_data_values => false, 
                                     :scale_integers => true, })


      lines.each{ |title,data|
        graph.add_data({ :data => data,
                         :title => title })
      }
      output << "Content-type: image/svg+xml\r\n\r\n"
      output << graph.burn()
    else
      raise KnownException, "Invalid argument for 'type': #{@type}"
    end

    output
  end
end
