# ## jsonld-rapper
JsonLD       = require 'jsonld'
Async        = require 'async'
ChildProcess = require 'child_process'
Merge        = require 'merge'

###

Middleware for Express that handles Content-Negotiation and sends the
right format to the client, based on the JSON-LD representation of the graph.

###

_error = (statusCode, msg, cause) ->
	err = new Error(msg)
	err.msg = msg
	err.statusCode = statusCode
	err.cause = cause if cause
	return err

# <h3>Supported Types</h3>
# The Middleware is able to output JSON-LD in these serializations

###
# Says `rapper --help`:
# ```
-i FORMAT, --input FORMAT   Set the input format/parser to one of:
    rdfxml          RDF/XML (default)
    ntriples        N-Triples
    turtle          Turtle Terse RDF Triple Language
    trig            TriG - Turtle with Named Graphs
    rss-tag-soup    RSS Tag Soup
    grddl           Gleaning Resource Descriptions from Dialects of Languages
    guess           Pick the parser to use using content type and URI
    rdfa            RDF/A via librdfa
    json            RDF/JSON (either Triples or Resource-Centric)
    nquads          N-Quads
```
###

_inputTypeMap = {
	'*':                            'guess'    # let rapper guess from the data
	'application/json':             'jsonld'
	'application/ld+json':          'jsonld'
	'application/rdf+json':         'json'
	'application/rdf-triples+json': 'json'
	'application/rdf-triples':      'ntriples'
	'application/x-turtle':         'turtle'
	'text/rdf+n3':                  'turtle'
	'application/trig':             'trig'
	'text/turtle':                  'turtle'
	'application/nquads':           'nquads'
	'application/rdf+xml':          'rdfxml'
	'text/xml':                     'rdfxml'
	'text/html':                    'html'
}
SUPPORTED_INPUT_TYPE = {}
for type, rapperType of _inputTypeMap
	SUPPORTED_INPUT_TYPE[type] = rapperType
	SUPPORTED_INPUT_TYPE[rapperType] = rapperType

###
```
-o FORMAT, --output FORMAT  Set the output format/serializer to one of:
    ntriples        N-Triples (default)
    turtle          Turtle Terse RDF Triple Language
    rdfxml-xmp      RDF/XML (XMP Profile)
    rdfxml-abbrev   RDF/XML (Abbreviated)
    rdfxml          RDF/XML
    rss-1.0         RSS 1.0
    atom            Atom 1.0
    dot             GraphViz DOT format
    json-triples    RDF/JSON Triples
    json            RDF/JSON Resource-Centric
    html            HTML Table
    nquads          N-Quads
```
###

_outputTypeMap = {
	'*':                            'turtle'       # Default to Turtle
	'application/json':             'jsonld'       #
	'application/ld+json':          'jsonld'       #
	'application/rdf+json':         'json'         #
	'application/rdf-triples+json': 'json-triples' #
	'application/rdf-triples':      'ntriples'     #
	'text/vnd.graphviz':            'dot'          #
	'application/x-turtle':         'turtle'       #
	'text/rdf+n3':                  'turtle'       #
	'text/turtle':                  'turtle'       #
	'application/nquads':           'nquads'       #
	'application/rdf+xml':          'rdfxml'       #
	'text/xml':                     'rdfxml'
	'text/html':                    'html'         # HTML table
	'application/atom+xml':         'atom'         #
	'.nt':                          'ntriples'
	'.n3':                          'turtle'
	'.rdf':                         'rdfxml'
}
SUPPORTED_OUTPUT_TYPE = {}
for type, rapperType of _outputTypeMap
	SUPPORTED_OUTPUT_TYPE[type] = rapperType 
	SUPPORTED_OUTPUT_TYPE[rapperType] = rapperType 

# <h3>JSON-LD profiles</h3>
JSONLD_PROFILE = 
	COMPACTED: 'http://www.w3.org/ns/json-ld#compacted'
	FLATTENED: 'http://www.w3.org/ns/json-ld#flattened'
	FLATTENED_EXPANDED: 'http://www.w3.org/ns/json-ld#flattened+expanded'
	EXPANDED:  'http://www.w3.org/ns/json-ld#expanded'


_to_rdf = (input, inputType, outputType, opts, cb) ->
	opts or= {}

	if not(inputType and outputType)
		return cb _error(500, "Must set inputType and outputType")

	# console.log "Spawn `rapper` with a '#{inputType}' parser and a serializer producing '#{outputType}'"
	cmd = "rapper -i #{inputType} -o #{outputType} - #{opts.baseURI}"
	rapperArgs = ["-i", inputType, "-o", outputType]
	for prefix, url of opts.expandContext
		rapperArgs.push "-f"
		rapperArgs.push "xmlns:#{prefix}=\"#{url}\""
	rapperArgs.push "-"
	rapperArgs.push opts.baseURI
	serializer = ChildProcess.spawn("rapper", rapperArgs)

	serializer.on 'error', (err) -> 
		return cb _error(500, 'Could not spawn rapper process')

	# When data is available, concatenate it to a buffer
	buf=''
	serializer.stdout.on 'data', (chunk) -> 
		buf += chunk.toString('utf8')

	# Capture error as well
	errbuf=''
	serializer.stderr.on 'data', (chunk) -> 
		errbuf += chunk.toString('utf8')

	# Pipe the RDF data into the process and close stdin
	serializer.stdin.write(input)
	serializer.stdin.end()

	# When rapper finished without error, return the serialized RDF
	serializer.on 'close', (code) ->
		if code isnt 0
			return cb _error(500,  "Rapper failed to convert #{inputType} to #{outputType}", errbuf)
		cb null, buf


# When parsing N-QUADS, jsonld produces data like in flat, expanded 
# _transform_jsonld assumes the data to be in that profile
_transform_jsonld = (input, opts, cb) ->
	switch opts.profile
		when JSONLD_PROFILE.COMPACTED, 'compact', 'compacted'
			return JsonLD.compact input, opts.expandContext, opts.jsonldCompact, cb
		when JSONLD_PROFILE.EXPANDED, 'expand', 'expanded'
			return JsonLD.expand input, opts.jsonldExpand, cb
		when JSONLD_PROFILE.FLATTENED, 'flatten', 'flattened'
			return JsonLD.flatten input, opts.expandContext, opts.jsonldFlatten, cb
		when JSONLD_PROFILE.FLATTENED_EXPANDED
			cb null, input
		else
			# TODO make this extensible
			return cb _error(500, "Unsupported profile: #{opts.profile}")

JsonLD2RDF = (moduleOpts) ->

	# <h3>Options</h3>
	moduleOpts or= {}
	# Context to expand object with (default: none)
	moduleOpts.expandContext or= {}
	# Base URI for RDF serializations that require them (i.e. all of them, hence the default)
	moduleOpts.baseURI or= 'http://example.com/FIXME/'
	# Default JSON-LD compaction profile to use if no other profile is requested (defaults to flattened)
	moduleOpts.profile or= JSONLD_PROFILE.FLATTENED_EXPANDED

	moduleOpts.jsonldToRDF or= {
		baseURI: moduleOpts.baseURI
		expandContext: moduleOpts.expandContext
		format: 'application/nquads'
	}
	moduleOpts.jsonldFromRDF or= {
		format: 'application/nquads'
		useRdfType: false
		useNativeTypes: false
	}
	moduleOpts.jsonldCompact or= {
		context: moduleOpts.expandContext
	}
	moduleOpts.jsonldExpand or= {
		expandContext: moduleOpts.expandContext
	}
	moduleOpts.jsonldFlatten or= {
		expandContext: moduleOpts.expandContext
	}

	# <h3>convert</h3>
	# Convert the things
	convert = (input, from, to, methodOpts, cb) ->

		if typeof methodOpts is 'function'
			cb = methodOpts
			methodOpts = {}
		methodOpts = Merge(moduleOpts, methodOpts)

		inputType = SUPPORTED_INPUT_TYPE[from]
		return cb _error(406, "Unsupported input format #{from}") if not inputType
		outputType = SUPPORTED_OUTPUT_TYPE[to] 
		return cb _error(406, "Unsupported output format #{to}") if not outputType

		# Catch the case of having to guess input is in JSON-LD
		if inputType is 'guess'
			if typeof input is 'object' or input.indexOf('@context') != -1
				inputType = 'jsonld'

		# For sake of sanity, convert with from==to should be a no-op, except when
		# doing JSON-LD profile transformations
		if inputType isnt 'jsonld' and inputType is outputType
			return cb null, input

		# console.log "Converting from '#{inputType}' to '#{outputType}'"

		# Convert a JSON-LD string / object ...
		if inputType is 'jsonld'
				if typeof input is 'string'
					input = JSON.parse(input)
				# to JSON-LD
				if outputType is 'jsonld'
					_transform_jsonld input, methodOpts, cb
				# to RDF
				else
					JsonLD.toRDF input, methodOpts.jsonldToRDF, (err, nquads) ->
						return cb _error(400, "jsonld-js could not convert this to N-QUADS", err) if err
						return cb null, nquads if outputType is 'nquads'
						return _to_rdf nquads, 'nquads', outputType, methodOpts, cb

		# Convert an RDF string / object ...
		else 
			if typeof input isnt 'string'
				return cb _error(500, "RDF data must be a string", input)
			# to JSON-LD
			if outputType is 'jsonld'
				return _to_rdf input, inputType, 'nquads', methodOpts, (err, nquads) ->
					return cb _error(400, "rapper could not convert this to N-QUADS", err) if err
					JsonLD.fromRDF nquads, methodOpts.jsonldFromRDF, (err, jsonld1) ->
						return cb _error(500, "JSON-LD failed to parse the N-QUADS", err) if err
						_transform_jsonld jsonld1, methodOpts, cb
			# to RDF
			else 
				return _to_rdf input, inputType, outputType, methodOpts, (err, rdf) ->
					return cb _error(500, "rapper could not convert this to N-QUADS", err) if err
					return cb null, rdf

	# Return
	return {
		convert:               convert
		JSONLD_PROFILE:        JSONLD_PROFILE
		SUPPORTED_INPUT_TYPE:  SUPPORTED_INPUT_TYPE
		SUPPORTED_OUTPUT_TYPE: SUPPORTED_OUTPUT_TYPE
	}

# ## Module exports	
module.exports = JsonLD2RDF

#ALT: test/middleware.coffee
