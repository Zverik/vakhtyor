<? // Vakhtyor: web interface configuration file. Written by Ilya Zverev, licensed WTFPL.

// OpenStreetMap OAuth parameters, see http://wiki.openstreetmap.org/wiki/OAuth
const CLIENT_ID     = '';
const CLIENT_SECRET = '';

const AUTHORIZATION_ENDPOINT = 'http://www.openstreetmap.org/oauth/authorize';
const TOKEN_ENDPOINT         = 'http://www.openstreetmap.org/oauth/access_token';
const REQUEST_ENDPOINT       = 'http://www.openstreetmap.org/oauth/request_token';
const OSM_API                = 'http://api.openstreetmap.org/api/0.6/';

// Database credentials
const DB_HOST     = 'localhost';
const DB_USER     = 'wdi';
const DB_PASSWORD = '';
const DB_DATABASE = 'wdi';
const DB_TABLE    = 'v_stats';

// Miscellaneous
const OBJ_LIMIT = 20; // Minimal number of changed buildings per day to matter
const PAGE_SIZE = 25; // Number of lines per page
const DEFAULT_USER = ''; // If set, this user is considered logged in by default
const LOG_FILE = 'vakhtyor.log'; // By default it's the directory of the script, anyone can see it
const MAP_URL = 'http://openstreetmap.ru/#lat=%s&lon=%s&zoom=17'; // a link to the map

?>
