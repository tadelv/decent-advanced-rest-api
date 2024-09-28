package require de1_machine 1.2
package require json
package require de1_profile 2.0
package require de1_vars 1.0
package require de1_utils 1.1

set plugin_name "advanced_rest_api"

namespace eval ::plugins::${plugin_name} {

    variable author "Yannick Dietler"
    variable contact "ydt@ydt.ch"
    variable version 1.2
    variable description "API to control the DE1's power state and getting additional Information"
    variable name "Advanced REST API"

	# based on Johanna Schander's Web API
    proc main {} {
        package require wibble

				if { ![plugins available SDB] || ![plugins available DYE] } {
					popup "SDB or DYE plugin not available"
					die "SDB or DYE plugin not available"
				}
				plugins preload SDB
				plugins preload DYE
        # Create settings if non-existant
        if {[array size ::plugins::advanced_rest_api::settings] == 0} {
            array set ::plugins::advanced_rest_api::settings {
                webserver_port 8888
                webserver_authentication_key "myFancyAuthenticationKey"
            }
            save_plugin_settings advanced_rest_api
        }

    

	# Auth

	proc ::wibble::check_auth {state} {
		set auth [dict getnull $state request query auth]
		set auth [lindex $auth 1]

		if {$auth eq "" && $::plugins::advanced_rest_api::settings(webserver_authentication) == 1} {
			return [unauthorized $state]
		}

		if {$auth != $::plugins::advanced_rest_api::settings(webserver_authentication_key) && $::plugins::advanced_rest_api::settings(webserver_authentication) == 1} {
			return [unauthorized $state]
		}

		return true;
	}

	proc ::wibble::unauthorized {state} {
		dict set response status 403
		dict set state response header content-type "" {application/json charset utf-8}
		dict set response content "{status: \"unauthorized\"}"
		sendresponse $response
		return false;
	}

	proc ::wibble::bad_request {state} {
		dict set response status 400
		dict set state response header content-type "" {application/json charset utf-8}
		dict set response content "{status: \"bad request\"}"
		sendresponse $response
		return false;
	}
	# Utilities

	proc ::wibble::return_200_json {content} {
		dict set response status 200
		dict set response header content-type {} application/json
		dict set response content "$content\n"
		sendresponse $response
	}
	# from https://wiki.tcl-lang.org/page/JSON
	proc ::wibble::compile_json {spec data} {
      while {[llength $spec]} {
          set type [lindex $spec 0]
          set spec [lrange $spec 1 end]

          switch -- $type {
              dict {
                  lappend spec * string

                  set json {}
                  foreach {key val} $data {
                      foreach {keymatch valtype} $spec {
                          if {[string match $keymatch $key]} {
                              lappend json [subst {"$key":[
                                  ::wibble::compile_json $valtype $val]}]
                              break
                          }
                      }
                  }
                  return "{[join $json ,]}"
              }
              list {
                  if {![llength $spec]} {
                      set spec string
                  } else {
                      set spec [lindex $spec 0]
                  }
                  set json {}
                  foreach {val} $data {
                      lappend json [::wibble::compile_json $spec $val]
                  }
                  return "\[[join $json ,]\]"
              }
              string {
                  if {[string is double -strict $data]} {
                      return $data
                  } else {
                      return "\"[::wibble::remove_newlines $data]\""
                  }
              }
              default {error "Invalid type"}
          }
      }
  }

	proc ::wibble::remove_newlines {input_string} {
    # Replace all newlines (\n) in the string with an escaped newline string
    set output_string [string map {\n "\\n"} $input_string]
    return $output_string
}
	# Index endpoint
	proc ::wibble::indexpage {state} {
		   if { ![check_auth $state] } {
			return;
		}
		set fp [open "[homedir]/[plugin_directory]/advanced_rest_api/index.html" r]
		set file_data [read $fp]
		close $fp

	  dict set state response status 200
		dict set state response header content-type "" text/html
		dict set state response content $file_data
		sendresponse [dict get $state response]
	}

	# Profile endpoints

	proc ::wibble::profile {state } {
		if { ![check_auth $state] } {
			return;
		}
		set method [dict get $state request method]		
		if {$method eq "POST"} {
      set rawheaders [dict get $state request rawheader]
      set filenameIndex [lsearch $rawheaders "filename:*"]
      if {$filenameIndex == -1 } {
        set profilePath "[clock seconds].tcl"  
      } else {
        set localfilename [lindex [split [lindex $rawheaders $filenameIndex] ": "] end]
				append profilePath [lindex [split $localfilename "."] 0] ".tcl"
      }
			set postdata [dict get $state request rawpost]
			variable profileData
			set profileData [::profile::v2_to_legacy $postdata]
			#if {[catch {
			#	set profileData [::profile::v2_to_legacy $postdata]
			#	set callImport 1
			#}]} {
			#	set profileData $postdata
			#}
			set path "[pwd]/profiles/$profilePath"
			set fileId [open $path "w"]
			puts -nonewline $fileId $profileData
			close $fileId
			#if {[info exists callImport]} {
			#	array set newProfile [::profile::read_legacy "profile_file" $path]
			#	::profile::import_legacy $newProfile(profile)
			#}
			::wibble::return_200_json "$localfilename written"
		}
		if {$method eq "GET"} {
		set path [dict get $state request path]
		set profile [lindex [split $path "/"] 3]
		#Load all saved profiles as a list
		set savedprofiles [glob -tails -directory [pwd]/profiles/ *.tcl]

		if {$profile != ""} {
			#Only return profile information if the profile exists
			if {$profile in $savedprofiles} {
				set fd [open "[pwd]/profiles/$profile" r]
				fconfigure $fd -translation binary
				set content [read $fd]; close $fd
				# ::wibble::return_200_json   [::wibble::compile_json {dict} $content]
				::wibble::return_200_json $content
			} else {
				#If a profile is specified but does not exist, return all profiles
				::wibble::return_200_json [::wibble::compile_json {list} $savedprofiles]
			}
		} else {
			#If no profile was specified, return all profiles
			::wibble::return_200_json [::wibble::compile_json {list} $savedprofiles]
		}
		}
		#Set a profile
		if {$method eq "PUT"} {
			set path [dict get $state request path]
			set profile [lindex [split $path "/"] 3]
			#Load all saved profiles as a list
			set savedprofiles [glob -tails -directory [pwd]/profiles/ *.tcl]
			#Only set the profile if it exists
			if {$profile in $savedprofiles} {
				#The select_profile procedure accepts the profile name without file extension (.tcl)
				set rootname [file rootname [file tail $profile]]
				select_profile $rootname
				::wibble::return_200_json "$profile"
			} else {
				::wibble::return_200_json [::wibble::compile_json {list} $savedprofiles]
			}
		}
		
	}
	

	#history
	proc ::wibble::history {state} {
		if { ![check_auth $state] } {
			return;
		}
		set path [dict get $state request path]
		set shot [lindex [split $path "/"] 3]


		if {$shot != ""} {
			set fd [open "[pwd]/history/$shot" r]
			fconfigure $fd -translation binary
			set content [read $fd]; close $fd
			::wibble::return_200_json $content
		} else {
			set shotlist [glob -tails -directory [pwd]/history/ *.shot]
			::wibble::return_200_json  [::wibble::compile_json "{list}" $shotlist]
		}
	}

    #history v2
  proc ::wibble::history_v2 {state} {
    if { ![check_auth $state] } {
			return;
		}
    set method [dict get $state request method]
    if { $method eq "PUT" } {
      return [set_next_shot_in_dye $state]
    }
		if { $method eq "POST" } {
			return;
		}
		set path [dict get $state request path]
		set shot [lindex [split $path "/"] 4]
    append shotName [lindex [split $shot "."] 0] ".json"

    if {$shotName != ""} {
			set fd [open "[pwd]/history_v2/$shotName" r]
			fconfigure $fd -translation binary
			set content [read $fd]; close $fd
			::wibble::return_200_json $content
		} else {
      ::wibble::return_200_json
    }
  }

  proc ::wibble::set_next_shot_in_dye { state } {
    set path [dict get $state request path]
		set shot [lindex [split $path "/"] 4]
    
    msg -INFO "shot name is ${shot}"
    
    set fields {
      workflow_settings
      shot_profile
      ratio
      drink_weight
      grinder_dose_weight 
      grinder_setting 
      grinder_model 
      workflow
      bean_brand
      bean_type
      roast_date
      roast_level
      bean_notes
    }
    ::plugins::DYE::shots::source_next_from $shot {} $fields
    ::wibble::return_200_json ""
  }

  proc ::wibble::history_sdb { state } {
    if { ![check_auth $state] } {
			return;
		}
    # TODO: check SDB plugin exists and is loaded
    array set loadedShots [::plugins::SDB::shots *]
    set jsonArray {}
    set listLength [llength $loadedShots(grinder_setting)]

    for {set i 0} {$i < $listLength} {incr i} {
      # Create a dictionary for each index
      set shotDict [dict create \
        clock [lindex $loadedShots(clock) $i] \
        grinder_setting   [lindex $loadedShots(grinder_setting) $i] \
        grinder_model    [lindex $loadedShots(grinder_model) $i] \
        profile_title  [lindex $loadedShots(profile_title) $i] \
        bean_desc   [lindex $loadedShots(bean_desc) $i] \
        bean_brand    [lindex $loadedShots(bean_brand) $i] \
        bean_type    [lindex $loadedShots(bean_type) $i] \
        bean_notes   [string map {\n \\n} [lindex $loadedShots(bean_notes) $i]] \
        drink_weight  [lindex $loadedShots(drink_weight) $i] \
        grinder_dose_weight   [lindex $loadedShots(grinder_dose_weight) $i] \
        target_drink_weight   [lindex $loadedShots(target_drink_weight) $i] \
        extraction_time    [lindex $loadedShots(extraction_time) $i] \
        filename  [lindex $loadedShots(filename) $i] \
        espresso_enjoyment   [lindex $loadedShots(espresso_enjoyment) $i] \
        espresso_notes    [string map {\n \\n} [lindex $loadedShots(espresso_notes) $i]] \
        shot_desc  [lindex $loadedShots(shot_desc) $i]] 

      # Append the dictionary to the jsonArray list
      lappend jsonArray $shotDict
    }
    ::wibble::return_200_json [::wibble::compile_json {list dict} $jsonArray]
  }

	proc ::wibble::update_shot_notes {state} {
    set method [dict get $state request method]
		if { ![check_auth $state] || $method ne "POST" } {
			return;
		}
		if { [dict get $state request rawpost] == "" } {
			::wibble::bad_request $state
		  return 
	  }
		set postdata [::json::json2dict [dict get $state request rawpost]]
		set path [dict get $state request path]
		set shot [lindex [split $path "/"] 5]
		if {[dict get $postdata espresso_notes] == ""} {
      ::wibble::return_200_json ""
			return 
		}

		array set notes [ list espresso_notes [dict get $postdata espresso_notes] ]
		::plugins::SDB::modify_shot_file $shot notes
		array set updatedShot [::plugins::SDB::load_shot $shot]

		::plugins::SDB::update_shot_description $updatedShot(clock) notes

    append shotName [lindex [split $shot "."] 0] ".shot"
		::shot::convert_legacy_to_v2 $shotName {} {} 0

		unset shotName
    append shotName [lindex [split $shot "."] 0] ".json"
		set fd [open "[pwd]/history_v2/$shotName" r]
		fconfigure $fd -translation binary
		set content [read $fd]; close $fd
		::wibble::return_200_json $content
	}

	# based on https://github.com/Testsubject1683/de1-mirror/tree/webapi
	proc ::wibble::status {} {
	
		# depending on the current state, we supply different type of data
		set return [dict create]
		set json_structure {dict state string}
		dict set return "state" $::de1_num_state($::de1(state))
		dict set return "substate" $::de1_substate_types($::de1(substate))
		dict set return "battery_percent" [battery_percent]
		dict set return "charger_on" $::de1(usb_charger_on)

		switch -- $::de1_num_state($::de1(state)) {
			"Idle" {
				dict set return "profile" [::profile::filename_from_title $::settings(profile_title)]
				dict set return "espresso_count" $::settings(espresso_count)
				dict set return "steaming_count" $::settings(steaming_count)
				dict set return "bean_brand" $::settings(bean_brand)
				dict set return "bean_type" $::settings(bean_type)
				dict set return "bean_notes" $::settings(bean_notes)
				dict set return "roast_date" $::settings(roast_date)
				dict set return "roast_level" $::settings(roast_level)
				dict set return "skin" [::profile::filename_from_title $::settings(skin)]
				dict set return "head_temperature" [expr [expr {floor([expr $::de1(head_temperature) * 100])} / 100]]
				dict set return "mix_temperature" [expr [expr {floor([expr $::de1(mix_temperature) * 100])} / 100]]
				dict set return "steam_heater_temperature" [expr [expr {floor([expr $::de1(steam_heater_temperature) * 100])} / 100]]
				dict set return "water_level_ml" [water_tank_level_to_milliliters $::de1(water_level)]
			}
			"Espresso" {
				foreach key [list "espresso_elapsed" "espresso_pressure" "espresso_weight" "espresso_flow" "espresso_flow_weight" "espresso_temperature_basket" "espresso_temperature_mix"] {
					#dict append ret "$key" [::${key} range 0 end]
					append json_structure " ${key} list"
					dict set return $key [split [::${key} range 0 end] " "]
				}
			}
		    "Sleep" {
			}
		    "GoingToSleep" {
			}
		    "Busy" {
			}
		    "Steam" {
			}
		    "HotWater" {
			}
		    "ShortCal" {
			}
		    "SelfTest" {
			}
		    "LongCal" {
			}
		    "Descale" {
			}
		    "FatalError" {
			}
		    "Init" {
			}
		    "NoRequest" {
			}
		    "SkipToNext" {
			}
		    "HotWaterRinse" {
			}
		    "SteamRinse" {
			}
		    "Refill" {
			}
		    "Clean" {
			}
		    "InBootLoader" {
			}
		    "AirPurge" {
			}
		}
		append json_structure " * string"
		::wibble::return_200_json [::wibble::compile_json $json_structure $return]
	}
	proc ::wibble::docs {state} {
		set fp [open "[homedir]/[plugin_directory]/advanced_rest_api/doc.json" r]
		set file_data [read $fp]
		close $fp

	    
		 ::wibble::return_200_json $file_data
	}

	proc ::wibble::state {state} {
		if { ![check_auth $state] } {
			return;
		}
		set method [dict get $state request method]
		set current_state $::de1_num_state($::de1(state))

		if {$method eq "GET"} {
			set path [dict get $state request path]
			
			switch -- $path {
				"/api/status/details" {
					::wibble::status
				}
				"/api/status" {
					if { $::de1_num_state($::de1(state)) != "Sleep" } {
						dict set state_response is_active true
						dict set state_response espresso_count $::settings(espresso_count)
					dict set state_response steaming_count $::settings(steaming_count)
					} else {
						dict set state_response is_active false
					}
					
					::wibble::return_200_json [::wibble::compile_json {dict} $state_response]
				}
			}
		}
		if  {$method eq "POST"} {
			set postdata [::json::json2dict [dict get $state request rawpost]]
			if {[dict exists $postdata active]} {
				set new_state [dict get $postdata active]
				switch -- $new_state {
					"false" {
					if {$current_state != "Sleep"} {
		 				start_sleep
		 			}
					 dict set state_change_response is_active false
					 	::wibble::return_200_json [::wibble::compile_json {dict} $state_change_response]
					
					}
					"true" {
						if {$current_state != "Idle"} {
		 				start_idle
		 			}
					 dict set state_change_response is_active true
					 	::wibble::return_200_json [::wibble::compile_json {dict} $state_change_response]
				}
				}
				

			} else {
				::wibble::return_200_json {}
			}	
			}
	}

	proc ::wibble::flushLog {state} {
		if { ![check_auth $state] } {
			return;
		}

		::logging::flush_log

		::wibble::return_200_json ""
	}



	proc ::profile::v2_to_legacy {json_string} {
			# Parse the JSON string into a TCL dictionary
			set json_parsed [json::json2dict $json_string]
			# Create an empty dictionary to store the TCL structure
			set tcl_output [dict create]

			# Add title and author to the dictionary
			dict set tcl_output profile_title [dict get $json_parsed title]
			dict set tcl_output author [dict get $json_parsed author]

			# Add beverage_type and notes to the dictionary
			dict set tcl_output beverage_type [dict get $json_parsed beverage_type]
			dict set tcl_output profile_notes [dict get $json_parsed notes]

			# Handle the steps section
			set steps_list [list]
			foreach step [dict get $json_parsed steps] {
					set step_dict [dict create]
					dict set step_dict exit_if 0
					foreach {key value} $step {
							if { $key eq "limiter" } {
									# Handle the limiter sub-dictionary
									set limiter [dict get $step limiter]
									#dict set step_dict limiter [list value [dict get $limiter value] range [dict get $limiter range]]
								  dict set step_dict max_flow_or_pressure_range [dict get $limiter range]
									dict set step_dict max_flow_or_pressure [dict get $limiter value]
							} elseif { $key eq "exit" } {
								  dict set step_dict exit_if 1
									set exit_dict [dict get $step "exit"]
									dict set step_dict "exit_[dict get $exit_dict type]_[dict get $exit_dict condition]" [dict get $exit_dict value]
									dict set step_dict exit_type "[dict get $exit_dict type]_[dict get $exit_dict condition]"
							} else {
									dict set step_dict $key $value
							}
					}
					lappend steps_list $step_dict
			}
			dict set tcl_output advanced_shot $steps_list

			# Add remaining fields to the dictionary
			dict set tcl_output tank_temperature [dict get $json_parsed tank_temperature]
			dict set tcl_output final_desired_shot_weight_advanced [dict get $json_parsed target_weight]
			dict set tcl_output final_desired_shot_volume_advanced [dict get $json_parsed target_volume]
			dict set tcl_output final_desired_shot_volume_advanced_count_start [dict get $json_parsed target_volume_count_start]
			dict set tcl_output settings_profile_type [dict get $json_parsed legacy_profile_type]
			dict set tcl_output type [dict get $json_parsed type]
			dict set tcl_output lang [dict get $json_parsed lang]
			dict set tcl_output profile_hide [dict get $json_parsed hidden]
			#dict set tcl_output reference_file [dict get $json_parsed reference_file]
			#dict set tcl_output version [dict get $json_parsed version]

			# Return the resulting TCL dictionary
			return $tcl_output
	}
	# Define handlers

		::wibble::handle /api/status state
        ::wibble::handle /api/flush flushLog
        ::wibble::handle /api/profile profile
		::wibble::handle /api/shot history
		::wibble::handle /api/help docs
		::wibble::handle /api/v2/shot/update update_shot_notes
    ::wibble::handle /api/v2/shot history_v2
    ::wibble::handle /api/v2/shots history_sdb
		::wibble::handle / indexpage
        # Start a server and enter the event loop if not already there.

        catch {
		::wibble::listen $::plugins::advanced_rest_api::settings(webserver_port)
        }

	}  ;# main
}
