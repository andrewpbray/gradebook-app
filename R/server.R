library(DT)
library(gradebook)
library(tidyverse)
library(plotly)
library(bslib)
library(readr)
library(shinydashboard)

#load helper scripts
HSLocation <- "helperscripts/"
source(paste0(HSLocation, "assignments.R"), local = TRUE)
source(paste0(HSLocation, "categories.R"), local = TRUE)
source(paste0(HSLocation, "lateness.R"), local = TRUE)
shinyServer(function(input, output, session) {
    
    #### -------------------------- UPLOADS ----------------------------####   
    
    data <- reactiveVal(NULL)
    
    #can only upload data that can be read in by read_gs()
    observeEvent(input$upload_gs,{
        req(input$upload_gs)
        tryCatch({
            uploaded_data <- gradebook::read_gs(input$upload_gs$datapath)
            data(uploaded_data)
        }, error = function(e) {
            showNotification('Please upload a file with the Gradescope format','',type = "error")
            
        })
    })
    
    observe({
        req(input$upload_policy)
        #eventually validate
        tryCatch({
            yaml <- gradebook::read_policy(input$upload_policy$datapath)
            policy$coursewide <- yaml$coursewide
            policy$categories <- yaml$categories
            #update lateness table
            flat_policy <- gradebook::flatten_policy(yaml)
            late_policies <- purrr::map(flat_policy$categories, "lateness") |>
                discard(is.null)
            late_table <- NULL
            for (late_policy in late_policies){
                late_policy <- list(late_policy)
                policy_name <- unname(sapply(late_policy, format_policy, simplify = FALSE))
                policy_name <- gsub("[^A-Za-z0-9_]", "", policy_name)
                #prevent duplicate lateness policies
                if (is.null(late_table) | !(policy_name %in% names(late_table))){
                    names(late_policy) <- policy_name
                    late_table <- append(late_table, late_policy)
                }
            }
            lateness$table <- late_table
            
        }, error = function(e) {
            showNotification('Please upload a policy file in YAML format','',type = "error")
        })
    })
    
   

    #### -------------------------- POLICY ----------------------------####  
    policy <- reactiveValues(coursewide = list(course_name = "Course Name", description = "Description"),
                             categories = list(
                                 list(
                                     category = "Overall Grade",
                                     aggregation = "weighted_mean",
                                     weight = 1,
                                     assignments = c()
                                 )
                             ),
                             letter_grades = list(),
                             exceptions = list(),
                             flat = list())
    
    grades <- reactiveVal(NULL)
    #### -------------------------- COURSEWIDE INFO ----------------------------####
    #modal to change saved course name + description
    observeEvent(input$edit_policy_name, {
        showModal(modalDialog(
            title = "Edit Policy",
            textInput("course_name_input", "Course Name", value = policy$coursewide$course_name),
            textInput("course_desc_input", "Course Description", value = policy$coursewide$description),
            footer = tagList(
                modalButton("Cancel"),
                actionButton("save_changes_course", "Save Changes")
            )
        ))
    })
    
    
    
    # When save_changes is clicked, update the reactive values and close modal
    observeEvent(input$save_changes_course, {
        policy$coursewide$course_name <- isolate(input$course_name_input)
        policy$coursewide$description <- isolate(input$course_desc_input)
        removeModal()
    })
    
    output$course_name_display <- renderText({policy$coursewide$course_name})
    
    output$course_description_display <- renderText({policy$coursewide$description})
    
    
    #### -------------------------- ASSIGNMENTS ----------------------------#### 
    
    #keeps track of which category each assignment is assigned to, if any
    assign <- reactiveValues(table = NULL)
    
    # creates assigns table when data uploads 
    # all assignments default to "Unassigned"
    observe({
        colnames <- gradebook::get_assignments(data())
        if(length(colnames) > 0){
            assign$table <- data.frame(assignment = colnames) |>
                mutate(category = "Unassigned")
        }
    })
    
    #a list of unassigned assignments in policies tab
    output$unassigned <- renderUI(
        if (!is.null(assign$table$assignment)){
            HTML(markdown::renderMarkdown(text = paste(paste0("- ", getUnassigned(assign$table), "\n"), collapse = "")))
        } else {
            h5('New assignments will appear here.')
        }
    )
    
    #### -------------------------- CATEGORIES MODAL ----------------------------####
    current_edit <- reactiveValues(category = NULL,
                                   lateness = NULL)
    modalIsOpen <- reactiveVal(FALSE)
    
    # Opening category modal to create a NEW category
    observeEvent(input$new_cat, {
        showModal(edit_category_modal) #opens edit modal
        #updates values that aren't always the same but still default
        current_edit$category <- NULL
        updateTextInput(session, "name", value = "Your Category name") #paste0("Category ", editing$num))
        #Gets the list of names of the policies
        if(!is.null(lateness$table)){
            key<- gsub("[^A-Za-z0-9_]", "", names(lateness$table))
            value <- unname(sapply(lateness$table, format_policy, simplify = FALSE))
            formatted_policies <-  setNames(
                key,
                value
            )
            updateSelectInput(session, "lateness_policies", choices = c("None"= "None", formatted_policies), selected = "None")
        }
        
        
        if (!is.null(assign$table)){ #updates assignments if data has been loaded
            choices <- getUnassigned(assign$table)
            updateSelectizeInput(session, "assignments", choices = choices, selected = "")
        }
        
    })
    
    observe({
        req(category_labels$edit)

        # Iterate over each category name to set up edit observers dynamically
        lapply(names(category_labels$edit), function(cat_name) {
            local({
                # Localize the variables to ensure they're correctly captured in the observer
                local_cat_name <- cat_name
                edit_id <- category_labels$edit[[local_cat_name]]
                
                observeEvent(input[[edit_id]], {
                    # Initialize a variable to hold the found category details
                    matched_category <- NULL
                    
                    # Iterate through policy$flat$categories to find a match
                    for (cat in policy$flat$categories) {
                        if (cat$category == cat_name) {  # Match found
                            matched_category <- cat
                            break
                        }
                    }
                    
                    if (!is.null(matched_category)) {
                        showModal(edit_category_modal) #opens edit modal
                        current_edit$category <- matched_category
                        cat_details <- matched_category
                        updateTextInput(session, "name", value = cat_details$category)
                        updateSelectInput(session, "aggregation", selected = cat_details$aggregation)
                        shinyWidgets::updateAutonumericInput(session, "weight", value = cat_details$weight*100)  
                        updateNumericInput(session, "n_drops", value = cat_details$drop_n_lowest)
                        updateSelectInput(session, "clobber", selected = cat_details$clobber)
                        
                        if(!is.null(lateness$table)) {
                            
                            key_formatted <- gsub("[^A-Za-z0-9_]", "", names(lateness$table))
                            value_formatted <- unname(sapply(lateness$table, format_policy, simplify = FALSE))
                            formatted_policies <-  setNames(
                                key_formatted,
                                value_formatted
                            )

                            #formatted_policies <- unname(sapply(lateness$table, format_policy, simplify = FALSE))
                            selected_policy <- c("None" = "None")
                            if (!is.null(cat_details$lateness)){
                                key_selected <- unname(sapply(list(cat_details$lateness), format_policy, simplify = FALSE))
                                key_selected <- gsub("[^A-Za-z0-9_]", "", key_selected)
                                value_selected <- unname(sapply(list(cat_details$lateness), format_policy, simplify = FALSE))
                                selected_policy <-  setNames(
                                    key_selected,
                                    value_selected
                                )
                            }

                            #selected_policy <- unname(sapply(list(cat_details$lateness), format_policy, simplify = FALSE))
                            

                            updateSelectInput(session, "lateness_policies", choices = c("None"="None", formatted_policies), selected = selected_policy)
                        }

                        #update assignments
                        choices <- c()
                        if (!is.null(assign$table)){ #updates assignments if data has been loaded
                            choices <- getUnassigned(assign$table)
                        }
                        selected = NULL
                        if (!is.null(matched_category$assignments)){
                            selected <- matched_category$assignments
                            choices <- c(choices, selected)
                        }
                        updateSelectizeInput(session, "assignments", choices = choices, selected = selected)
                    } else {
                        showNotification("Please pick a category to edit", type = 'error')
                    }
                },         ignoreInit = TRUE)
            })
        })
        
    })   
    
    # Cancel and no changes will be made
    observeEvent(input$cancel,{
        removeModal() #closes edit modal
        
    })
    
    observeEvent(input$save,{
        existingCategories <- unlist(map(policy$flat$categories, "category"))
        if (!is.null(assign$table$assignment)){
            existingCategories <- c(existingCategories, gradebook::get_assignments(data()))
        }
        if (!is.null(current_edit$category)){
            existingCategories <- existingCategories[existingCategories != current_edit$category$category]
        }
        if(!is.null(existingCategories)  & input$name %in% existingCategories) {
            showNotification("Please enter a different category name. You cannot have repeating names. ", type = "error")
        }else{
            removeModal() #closes edit modal
            
            #collapse advances block on "save"
            advanced_visible(FALSE)
            sum <- 0
            if (!is.null(assign$table) & !is.null(input$assignments)){
                sum <- sum(input$assignments %in% assign$table[["assignment"]])/length(input$assignments)
            }
            
            
            if (sum %in% c(0,1)){
                #update policy
                if (!is.null(current_edit$category$category)){
                    
                    #add new category
                    policy$categories <- updateCategory(policy$categories, policy$flat, current_edit$category$category,
                                                        input$name, input, assign$table, lateness$table)
                    
                   
                } else {
                    policy$categories <- append(policy$categories,
                                                list(createCategory(input$name, input = input,
                                                                    assign$table, lateness$table)))
                }
            } else {
                showNotification('You cannot combine subcategories and assignments; please try again','',type = "error")
            }
        }
    })
    
    observe({
        names <- purrr::map(policy$flat$categories, "category") |> unlist()
        if (!is.null(names)){
            updateSelectInput(session, "edit_cat", choices = names)
        } else {
            updateSelectInput(session, "edit_cat", choices = "")
        }
    })
    
    category_to_be_deleted <- reactiveValues(cat = NULL)
    observe({
        req(category_labels$delete)
        
        # Iterate over each category name to set up edit observers dynamically
        lapply(names(category_labels$delete), function(cat_name) {
            local({
                # Localize the variables to ensure they're correctly captured in the observer
                local_cat_name <- cat_name
                delete_id <- category_labels$delete[[local_cat_name]]
                
                observeEvent(input[[delete_id]], {
                    
                    # Initialize a variable to hold the found category details
                    matched_category <- NULL
                    
                    # Iterate through policy$flat$categories to find a match
                    for (cat in policy$flat$categories) {
                        if (cat$category == cat_name) {  # Match found
                            matched_category <- cat
                            break
                        }
                    }
                    
                    if (!is.null(matched_category)) {
                        showModal(confirm_delete)
                        category_to_be_deleted$cat <- matched_category
                        
                    } else {
                        showNotification("Please pick a category to delete",type = 'error')
                    }
                },ignoreInit = TRUE)
            })
        })
    })
    
    observeEvent(input$delete, {
        req(category_to_be_deleted$cat)
        removeModal()
        policy$categories <- deleteCategory(policy$categories, category_to_be_deleted$cat$category)
        category_to_be_deleted$cat <- NULL
    })
    
    #whenever policy$categories changes, policy$flat, assign$table and UI updates
    observe({
        policy$flat <- list(categories = policy$categories) |> gradebook::flatten_policy()
        assign$table <- updateAssignsTable(assign$table, gradebook::flatten_policy(list(categories = policy$categories)))
    })
    
    #### -------------------------- DISPLAY CATEGORIES UI ----------------------------####
    
    category_labels <- reactiveValues(edit = list(), delete = list())
    
    
    observe({
        req(policy$flat$categories)
        category_levels <- assignLevelsToCategories(policy$flat$categories)
        result <- createNestedCards(policy$flat$categories, category_levels)
        
        output$categoriesUI <- renderUI({
            result$ui
        })
        
        # Store the labels returned from createNestedCards function
        category_labels$edit <- result$labels$edit
        category_labels$delete <- result$labels$delete
        
    })
    
    #### -------------------------- LATENESS POLICIES ----------------------------####
    
    lateness <- reactiveValues(
        default = NULL,
        policy_name = " ",
        prepositions = list(),
        starts = list(),
        ends = list(),
        arithmetics = list(),
        values = list(),
        num_late_cats = 1,
        table = list(),
        edit = list(),
        delete = list()
    )
    # Opening category modal to create a NEW LATENESS
    observeEvent(input$new_lateness, {
        showModal(edit_lateness_modal) #opens lateness modal
        current_edit$lateness <- NULL
        lateness$prepositions <- list()
        lateness$starts <- list()
        lateness$ends <- list()
        lateness$arithmetics <- list()
        lateness$values <- list()
        lateness$num_late_cats <- 1
 
    })
    
    observeEvent(input$add_interval, {
        lateness$num_late_cats <- lateness$num_late_cats + 1
        recordValues(as.integer(lateness$num_late_cats) - 1)
    })
    
    observeEvent(input$remove_interval, {
        if (lateness$num_late_cats > 1) { # Ensure at least one interval remains!
            lateness$num_late_cats <- lateness$num_late_cats - 1
        }
    })
    
    recordValues <- function(iterations){
        for (i in 1:iterations){
            lateness$prepositions[i] <- input[[paste0("lateness_preposition", i)]]
            lateness$starts[i] <- input[[paste0("start", i)]]
            lateness$ends[i] <- ifelse(lateness$prepositions[i] == "Between",
                                       input[[paste0("end", i)]],
                                       NA
            )
            lateness$arithmetics[i] <- input[[paste0("lateness_arithmetic", i)]]
            lateness$values[i] <- input[[paste0("lateness_value", i)]]
        }
    }
    
    output$lateness_modal <- generate_lateness_ui(lateness)
    
    
    observeEvent(input$save_lateness,{
        old_late_categories <- c()
        if (!is.null(current_edit$lateness)){
            #if editing, remove old policy
            current_lateness <- lateness$table[[current_edit$lateness]]
            old_late_categories <- map(policy$flat$categories, function(cat){
                if (identical(current_lateness, cat$lateness)){
                    return (cat$category)
                }
            }) |> unlist()
            lateness$table[[current_edit$lateness]] <- NULL
        }
        #make an empty list
        late_policy <- list()
        #loop over each interval
        for (i in 1:as.integer(lateness$num_late_cats)){
            #loop over each key
            for (key in list(c("lateness_preposition", "start"),
                             c("lateness_arithmetic", "lateness_value")
            )){
                # extract the value from the input 
                item <- input[[paste0(key[2], i)]] 
                if (input[[paste0(key[1], i)]] == "Between") {
                    # Directly create a named list for 'Between' intervals
                    between <-list(between = list(
                        from = input[[paste0("start", i)]],
                        to = input[[paste0("end", i)]]
                    ))
                    late_policy <- append(late_policy, list(between))
                } else {
                    # For 'Until' and 'After', add the details directly to late_policy!
                    threshold <- list(input[[paste0(key[2], i)]])
                    names(threshold) <- tolower(input[[paste0(key[1], i)]])
                    late_policy <- append(late_policy, list(threshold))
                }
                
            }
        }
        
        
        # appnd late_policy list to lateness$table using the policy name as the key!
        late_policy <- list(late_policy)
 
        policy_name <- unname(sapply(late_policy, format_policy, simplify = FALSE))
        policy_name <- gsub("[^A-Za-z0-9_]", "", policy_name)
        
        names(late_policy) <- policy_name
        lateness$table <- append(lateness$table, late_policy)
        if (length(old_late_categories) != 0){
            #update categories with old version lateness policy
            for (category_name in old_late_categories){
                policy$categories <- update_lateness(policy$categories, category_name, lateness$table[[policy_name]])
            }
        }
        
        removeModal()
    })
    
    observe({
        final_policy <<- list(categories = policy$categories)
    })
    
    #### -------------------------- ADVANCED LATENESS POLICIES UI ----------------------------####
    
    advanced_visible <- reactiveVal(FALSE)
    
    # Observe the toggle button
    observeEvent(input$advanced_toggle_lateness, {
        # Toggle the visibility
        advanced_visible(!advanced_visible())
    })
    
    #Render the advanced panel UI based on visibility
    output$advanced_lateness_policies_panel <- renderUI({
        if(advanced_visible()) {
            div(
                selectInput("clobber", "Clobber with:", selected = "None", choices = c("None"))
            )
        }
    })
    
    
    #### -------------------------- DISPLAY LATENESS POLICIES UI ----------------------------####
    
    
    observe({
        output$latenessUI <- renderUI({
            req(lateness$table)
            late_policy_names <- names(lateness$table) |> unlist()
            lateness$edit <- paste0('lateness_edit_', late_policy_names) #delete button names
            lateness$delete <- paste0('lateness_delete_', late_policy_names) #edit button names
            createLatenessCards(lateness$table)
        })
    })

    
    observe({
        req(lateness$edit)
        
        # Iterate over each category name to set up edit observers dynamically
        lapply(lateness$edit, function(late_name) {
            local({
                # Localize the variables to ensure they're correctly captured in the observer
                
                observeEvent(input[[late_name]], {
                    # Initialize a variable to hold the found category details
                    late_name <- str_remove(late_name, "lateness_edit_")
                    matched_policy <- lateness$table[[late_name]]
                    
                    if (!is.null(matched_policy)) {
                        current_edit$lateness <- late_name
                        
                        lateness$prepositions <- unlist(map(matched_policy, names))[c(TRUE, FALSE)] |> ucfirst()
                        lateness$num_late_cats <-  length(lateness$prepositions)
                        lateness$starts <- list()
                        lateness$ends <- list()
                        lateness$arithmetics <- unlist(map(matched_policy, names))[c(FALSE, TRUE)] |> ucfirst()
                        lateness$values <- list()
                        walk(matched_policy, function(policy){
                            if (names(policy) %in% c("after", "until")){
                                lateness$starts <- append(lateness$starts, policy)
                                lateness$ends <- append(lateness$ends, NA)
                            } else if (names(policy) == "between"){
                                lateness$starts <- append(lateness$starts, unlist(policy)[1])
                                lateness$ends <- append(lateness$ends, unlist(policy)[2])
                            } else {
                                lateness$values <- append(lateness$values, policy)
                            }
                        })
                        showModal(edit_lateness_modal) #opens edit modal
                        
                    } else {
                        showNotification("Please pick a lateness policy to edit", type = 'error')
                    }
                },         ignoreInit = TRUE)
            })
        })
        
    })
    
    lateness_to_be_deleted <- reactiveValues(policy = NULL)
    
    
    observe({
        req(lateness$delete)
        
        # Iterate over each category name to set up edit observers dynamically
        lapply(lateness$delete, function(late_name) {
            local({
                # Localize the variables to ensure they're correctly captured in the observer
                
                observeEvent(input[[late_name]], {
                    
                    # Initialize a variable to hold the found category details
                    late_name <- str_remove(late_name, "lateness_delete_")
                    matched_policy <- lateness$table[[late_name]]
                    
                    if (!is.null(matched_policy)) {
                        showModal(confirm_delete_lateness)
                        lateness_to_be_deleted$policy <- late_name
                        
                    } else {
                        showNotification("Please pick a category to delete",type = 'error')
                    }
                },ignoreInit = TRUE)
            })
        })
    })
    
    observeEvent(input$delete_late,{
        lateness$table[[lateness_to_be_deleted$policy]] <- NULL
        removeModal()
    }, ignoreInit = TRUE)
    
    #### -------------------------- GRADING ----------------------------####
    
    observe({
        if (!is.null(data()) & length(policy$categories) != 0){
            tryCatch({
                gs <- data()
                policy <- list(categories = policy$categories)
                
                final_grades <- gradebook::get_grades(gs = gs, policy = policy)
                grades(final_grades)
                
            }, error = function(e) {
                #do not show the error message currently!
                #showNotification('Fix policy file','',type = "error")
            })
        }
    })
    
    
    #### -------------------------- DASHBOARD ----------------------------####
    
    output$dashboard <- renderUI({
        # if categories are made OR data is uploaded.
        if (length(policy$categories) > 0 && !is.null(assign$table$assignment)) {
            fluidRow(
                box(
                    tabsetPanel(
                        tabPanel('Plot', 
                                 plotlyOutput('assignment_plotly', height = '220px')
                        ),
                        tabPanel('Statistics', 
                                 # TODO
                                 uiOutput('assignment_stats'),
                        ),
                    ),
                    width = 6,
                    height = '300px',
                ),
                box(
                    title = 'Assignment Options',
                    selectInput('which_assignment', label=NULL, choices = assign$table$assignment),
                    # TODO: radioButtons('assignment_score_option', 'Choose an option:', 
                    #              choices = list('Percentage' = 'percentage', 
                    #                             'By Points' = 'point'),
                    #              selected = 'percentage'),
                    width = 6,
                    height = '300px'
                    
                ),
                box(
                    tabsetPanel(
                        tabPanel('Plot', 
                                 plotlyOutput('category_plotly', height = '220px'),
                        ),
                        tabPanel('Statistics', 
                                 # TODO
                                 uiOutput('category_stats', height = '200px'),
                        ),
                    ),
                    width = 6,
                    height = '300px'
                ),
                box(
                    title = 'Category Options', 
                    selectInput('which_category', label=NULL, choices = available_categories()),
                    # TODO: radioButtons('choice2', 'Choose an option:',
                    #              choices = list('Percentage' = 'percentage', 
                    #                             'By Points' = 'point'),
                    #              selected = 'percentage'),
                    width = 6,
                    height = '300px'
                ),
                box(
                    title = 'Overall Course Distribution',
                    plotlyOutput('overall_plotly', height = '320px'),
                    width = 12,
                    height = '400px'
                ),
                box(
                    DT::DTOutput('course_data_table'),
                    width = 12
                )
            )
        } else if (length(policy$categories) > 0) { # policy is created only
            tags$div(style = 'display: flex; flex-direction: column; justify-content: center; align-items: center; height: 60vh;',
                     tagList(
                         h4(strong('You haven\'t uploaded any student data yet.')),
                         h5('Upload course data from Gradescope to get started.')
                     )
            )
        } else if (!is.null(assign$table$assignment)) {
            tags$div(style = 'display: flex; flex-direction: column; justify-content: center; align-items: center; height: 60vh;',
                     tagList(
                         h4(strong('You still need to build your course policy.')),
                         h5('See "Policies" tab to get started.')
                     )
            )
        } else {
            tags$div(style = 'display: flex; flex-direction: column; justify-content: center; align-items: center; height: 60vh;',
                     tagList(
                         h4(strong('You haven\'t uploaded any student data yet.')),
                         h5('Summary statistics and plots will appear here as you build your course policy.')
                     )
            )
        }
    })
    
    output$assignment_plotly <- renderPlotly({
        assignment_grades <- data() |>
            dplyr::select(input$which_assignment) |>
            dplyr::pull(1)
        # if (input$assignment_score_option == 'point') {
        #     assignment_grades
        # }
        
        plt <- plot_ly(x = ~assignment_grades, type='histogram') |>
            config(displayModeBar = FALSE) |>
            layout(
                title = list(text = 'Assignment Distribution', font = list(size = 14), y = 0.95),
                xaxis = list(title = 'percentage'),
                dragmode = FALSE
            )
        
        plt
    })
    
    output$assignment_stats <- renderUI({
        assignment_vec <- data() |>
            dplyr::select(input$which_assignment) |> 
            drop_na() |>
            dplyr::pull(1)
        
        mu <- mean(assignment_vec) |> round(digits = 4)
        med <- median(assignment_vec) |> round(digits = 4)
        sd <- sd(assignment_vec) |> round(digits = 4)
        tfive <- quantile(assignment_vec, 0.25) |> round(digits = 4)
        sfive <- quantile(assignment_vec, 0.75) |> round(digits = 4)
        
        HTML(paste0(
            '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>Mean</p> <p>', mu, '</p></div>',
            '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>Standard Deviation</p> <p>', sd, '</p></div>',
            '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>Median</p> <p>', med, '</p></div>',
            '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>25%ile</p> <p>', tfive, '</p></div>',
            '<div style="display: flex; justify-content: space-between; padding: 5px 0;"><p>75%ile</p> <p>', sfive, '</p></div>'
        ))
    })
    
    output$category_plotly <- renderPlotly({
        if (!is.null(grades())){
            category_grades <- grades() |>
                dplyr::select(input$which_category) |>
                dplyr::pull(1)
            
            plt <- plot_ly(x = ~category_grades, type = 'histogram') |>
                config(displayModeBar = FALSE) |>
                layout(
                    title = list(text = 'Category Distribution', font = list(size = 14), y = 0.95),
                    xaxis = list(title = 'percentage'),
                    dragmode = FALSE
                )
            
            plt
        }
    })
    
    output$category_stats <- renderUI({
        if (!is.null(grades())){
            category_vec <- grades() |>
                dplyr::select(input$which_category) |> 
                drop_na() |>
                dplyr::pull(1)
            
            mu <- paste0((mean(category_vec) |> round(digits = 4)) * 100, '%')
            med <- paste0((median(category_vec) |> round(digits = 4)) * 100, '%')
            sd <- paste0((sd(category_vec) |> round(digits = 4)) * 100, '%')
            tfive <- paste0((quantile(category_vec, 0.25) |> round(digits = 4)) * 100, '%')
            sfive <- paste0((quantile(category_vec, 0.75) |> round(digits = 4)) * 100, '%')
            
            HTML(paste0(
                '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>Mean</p> <p>', mu, '</p></div>',
                '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>Standard Deviation</p> <p>', sd, '</p></div>',
                '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>Median</p> <p>', med, '</p></div>',
                '<div style="display: flex; justify-content: space-between; border-bottom: 1px solid black; padding: 5px 0;"><p>25%ile</p> <p>', tfive, '</p></div>',
                '<div style="display: flex; justify-content: space-between; padding: 5px 0;"><p>75%ile</p> <p>', sfive, '</p></div>'
            ))
        }
    })
    
    output$overall_plotly <- renderPlotly({
        if (!is.null(grades())){
            plt <- plot_ly(x = grades()$`Overall Grade`, type = 'histogram') |>
                config(displayModeBar = FALSE) |>
                layout(dragmode = FALSE)
            plt
        }
    })
    
    output$course_data_table <- DT::renderDT({ 
        if (!is.null(grades())){
            # Don't display any lateness columns
            grades_for_DT <- grades() |>
                select(!ends_with(" - Submission Time")) |>
                select(!ends_with(" - Lateness (H:M:S)")) |>
                select(!contains("Total Lateness"))
            
            DT::datatable(grades_for_DT, options = list(scrollX = TRUE, scrollY = '500px'))
        }
    })
    
    available_categories <- reactive({
        #can plot any category with valid assignments/nested categories
        policy <- gradebook::flatten_policy(list(categories = policy$categories))
        return(map(policy$categories, "category"))
    })
    
    #### -------------------------- DOWNLOAD FILES ----------------------------####   
    
    output$download_policy_file <- downloadHandler(
        filename = function() {
            paste0(str_remove(policy$coursewide$course_name, "[^a-zA-Z0-9]"),"policy", ".yml")
        },
        content = function(file) {
            yaml::write_yaml(list(coursewide = policy$coursewide,
                                  categories = policy$categories,
                                  exceptions = policy$exceptions), file)
        }
    )
    
    output$download_grades <- downloadHandler(
        filename = function() {
            paste0(str_remove(policy$coursewide$course_name, "[^a-zA-Z0-9]"),"Grades", ".csv")
        },
        content = function(file) {
            readr::write_csv(grades(), file)
        }
    )
    
    #### -------------------------- DATA FILES ----------------------------####   
    # print out uploaded Gradescope data
    output$original_gs <- DT::renderDT({
        datatable(data(), options = list(scrollX = TRUE, scrollY = "500px"))
    })
    
    #print out assignment table
    output$assigns_table <- DT::renderDT({ assign$table })
    
    #shows policy$categories in Scratchpad under policy_list tab
    output$policy_list <- renderPrint({
        Hmisc::list.tree(list(coursewide = policy$coursewide, 
                              categories = policy$categories, 
                              letter_grades = policy$letter_grades,
                              exceptions = policy$exceptions))
    })
    
    output$flat_policy_list <- renderPrint({
        Hmisc::list.tree(policy$flat)
    })
    
    output$grades <- DT::renderDT({ 
        datatable(grades(), options = list(scrollX = TRUE, scrollY = "500px"))
    })
})