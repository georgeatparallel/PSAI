BeforeDiscovery {
    Import-Module "$PSScriptRoot/../PSAI.psd1" -Force
}

Describe 'Parallel MCP tools' {
    InModuleScope PSAI {
        BeforeEach {
            $script:requests = [System.Collections.Generic.List[object]]::new()
            $script:replyMode = 'json'
            Mock Invoke-WebRequest {
                param($Uri, $Method, $ContentType, $Headers, $UserAgent, $Body, $TimeoutSec, $ConnectionTimeoutSeconds, $OperationTimeoutSeconds)
                $message = $Body | ConvertFrom-Json -Depth 20
                $script:requests.Add(@{
                    Uri = $Uri; Method = $Method; ContentType = $ContentType
                    Headers = $Headers.Clone(); UserAgent = $UserAgent
                    Message = $message
                    TimeoutSec = if ($ConnectionTimeoutSeconds) { $ConnectionTimeoutSeconds } else { $TimeoutSec }
                    OperationTimeoutSeconds = $OperationTimeoutSeconds
                })
                if ($message.method -eq 'initialize') {
                    return @{
                        Headers = @{ 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = 'fixture-session' }
                        Content = '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26"}}'
                    }
                }
                if ($message.method -eq 'notifications/initialized') {
                    return @{ Headers = @{}; Content = '' }
                }
                $reply = @{
                    jsonrpc = '2.0'; id = 2
                    result = @{ content = @(@{ type = 'text'; text = '{"results":[{"url":"https://learn.microsoft.com/powershell/","excerpts":["PowerShell is a task automation solution."]}],"warnings":[],"errors":[]}' }) }
                }
                switch ($script:replyMode) {
                    'tool-error' { $reply.result.isError = $true; $reply.result.content[0].text = 'Free-tier limit reached' }
                    'rpc-error' { $reply.Remove('result'); $reply.error = @{ code = -32602; message = 'Invalid tool arguments' } }
                    'wrong-id' { $reply.id = 99 }
                    'empty' { $reply.result.content = @() }
                    'http-error' { throw 'HTTP 429 Too Many Requests; Retry-After: 60' }
                }
                $json = $reply | ConvertTo-Json -Depth 20 -Compress
                if ($script:replyMode -eq 'sse') {
                    return @{
                        Headers = @{ 'Content-Type' = 'text/event-stream; charset=utf-8' }
                        Content = "event: message`r`ndata: {`"jsonrpc`":`"2.0`",`"method`":`"notifications/progress`"}`r`n`r`nevent: message`r`ndata: $json`r`n`r`n"
                    }
                }
                @{ Headers = @{ 'Content-Type' = 'application/json' }; Content = $json }
            }
        }

        It 'initializes anonymous HTTP MCP and preserves queries, headers, timeout and useful output' {
            $text = Search-ParallelWeb -Objective 'Find PowerShell docs' -SearchQueries 'PowerShell docs', 'Microsoft PowerShell guide' -TimeoutSec 17
            ($text | ConvertFrom-Json).results[0].url | Should -Be 'https://learn.microsoft.com/powershell/'
            $script:requests.Count | Should -Be 3
            ($script:requests.Message.method -join ',') | Should -Be 'initialize,notifications/initialized,tools/call'
            foreach ($request in $script:requests) {
                $request.Uri | Should -Be 'https://search.parallel.ai/mcp'
                $request.Method | Should -Be 'Post'
                $request.ContentType | Should -Be 'application/json'
                $request.UserAgent | Should -Be "PSAI/$((Get-Module PSAI).Version) (https://github.com/dfinke/PSAI)"
                $request.TimeoutSec | Should -Be 17
                if ((Get-Command Microsoft.PowerShell.Utility\Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
                    $request.OperationTimeoutSeconds | Should -Be 17
                }
                $request.Headers.Accept | Should -Be 'application/json, text/event-stream'
                $request.Headers.ContainsKey('Authorization') | Should -BeFalse
                $request.Headers.ContainsKey('x-api-key') | Should -BeFalse
            }
            $script:requests[0].Headers.ContainsKey('Mcp-Session-Id') | Should -BeFalse
            $script:requests[1].Headers['Mcp-Session-Id'] | Should -Be 'fixture-session'
            $script:requests[2].Headers['MCP-Protocol-Version'] | Should -Be '2025-03-26'
            $argsSent = $script:requests[2].Message.params.arguments
            $argsSent.objective | Should -Be 'Find PowerShell docs'
            $argsSent.search_queries.Count | Should -Be 2
            $argsSent.search_queries[1] | Should -Be 'Microsoft PowerShell guide'
            $argsSent.session_id | Should -Be $script:ParallelSessionId
        }

        It 'fetches excerpts and shares the anonymous conversation identifier with search' {
            $null = Search-ParallelWeb -Objective 'Find docs' -SearchQueries 'PowerShell docs'
            $text = Get-ParallelWebContent -Urls 'https://learn.microsoft.com/powershell/' -Objective 'What is PowerShell?'
            $text | Should -Match 'task automation'
            $call = $script:requests[5].Message.params
            $call.name | Should -Be 'web_fetch'
            $call.arguments.urls.Count | Should -Be 1
            $call.arguments.urls[0] | Should -Be 'https://learn.microsoft.com/powershell/'
            $call.arguments.objective | Should -Be 'What is PowerShell?'
            $call.arguments.session_id | Should -Be $script:requests[2].Message.params.arguments.session_id
            $call.arguments.PSObject.Properties.Name | Should -Not -Contain 'full_content'
        }

        It 'omits an unspecified fetch objective' {
            $null = Get-ParallelWebContent -Urls 'https://learn.microsoft.com/powershell/'
            $script:requests[2].Message.params.arguments.PSObject.Properties.Name | Should -Not -Contain 'objective'
        }

        It 'accepts a Streamable HTTP SSE response with a preceding notification' {
            $script:replyMode = 'sse'
            Search-ParallelWeb -Objective 'Find docs' -SearchQueries 'PowerShell docs' | Should -Match 'task automation'
        }

        It 'reports <Mode> to the caller' -TestCases @(
            @{ Mode = 'tool-error'; Expected = '*Free-tier limit reached*' }
            @{ Mode = 'rpc-error'; Expected = '*MCP error -32602: Invalid tool arguments*' }
            @{ Mode = 'wrong-id'; Expected = '*Missing matching MCP response*' }
            @{ Mode = 'empty'; Expected = '*returned no text content*' }
            @{ Mode = 'http-error'; Expected = '*429*Retry-After: 60*' }
        ) {
            param($Mode, $Expected)
            $script:replyMode = $Mode
            { Search-ParallelWeb -Objective 'Find docs' -SearchQueries 'PowerShell docs' } | Should -Throw $Expected
        }

        It 'rejects unsupported URL schemes and out-of-range timeouts before HTTP' {
            { Get-ParallelWebContent -Urls 'file:///etc/passwd' } | Should -Throw
            { Search-ParallelWeb -Objective 'Find docs' -SearchQueries 'PowerShell docs' -TimeoutSec 0 } | Should -Throw
            $script:requests.Count | Should -Be 0
        }

        It 'registers both functions and dispatches search and fetch through the PSAI agent loop' {
            $script:modelTurn = 0
            Mock Invoke-OAIChatCompletion {
                param($Messages, $Tools)
                $Tools.function.name | Should -Contain 'Search-ParallelWeb'
                $Tools.function.name | Should -Contain 'Get-ParallelWebContent'
                $script:modelTurn++
                if ($script:modelTurn -le 2) {
                    $name = if ($script:modelTurn -eq 1) { 'Search-ParallelWeb' } else { 'Get-ParallelWebContent' }
                    $arguments = if ($script:modelTurn -eq 1) {
                        '{"Objective":"Find PowerShell docs","SearchQueries":["PowerShell documentation"]}'
                    }
                    else { '{"Urls":["https://learn.microsoft.com/powershell/"],"Objective":"What is PowerShell?"}' }
                    return @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                        role = 'assistant'; content = $null; tool_calls = @(@{
                            id = "call-$script:modelTurn"; type = 'function'; function = @{ name = $name; arguments = $arguments }
                        })
                    } }) }
                }
                $toolMessages = @($Messages | Where-Object role -EQ 'tool')
                $toolMessages.Count | Should -Be 2
                foreach ($message in $toolMessages) { $message.content | Should -Match 'task automation' }
                @{ choices = @(@{ finish_reason = 'stop'; message = @{ role = 'assistant'; content = 'PowerShell automates tasks: https://learn.microsoft.com/powershell/' } }) }
            }
            $providerBefore = Get-OAIProvider
            $agent = New-Agent -Tools 'Search-ParallelWeb', 'Get-ParallelWebContent'
            $agent | Get-AgentResponse 'Find PowerShell docs and read them.' | Should -Match 'https://learn.microsoft.com/powershell/'
            $script:modelTurn | Should -Be 3
            $script:requests.Count | Should -Be 6
            Get-OAIProvider | Should -Be $providerBefore
        }

        It 'adds MCP failures to agent tool messages' {
            $script:replyMode = 'tool-error'
            $response = @{ choices = @(@{ message = @{ tool_calls = @(@{
                id = 'failed-call'; function = @{ name = 'Search-ParallelWeb'; arguments = '{"Objective":"Find docs","SearchQueries":["PowerShell docs"]}' }
            }) } }) }
            $message = Invoke-OAIFunctionCall $response
            $message.role | Should -Be 'tool'
            $message.tool_call_id | Should -Be 'failed-call'
            $message.content | Should -Match 'Free-tier limit reached'
        }
    }
}
