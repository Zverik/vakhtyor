<? // Vakhtyor (Вахтёр): web-interface to illegal buildings monitoring tool. Written by Ilya Zverev, licensed WTFPL.
require('config.php');

$php_self = htmlentities(substr($_SERVER['PHP_SELF'], 0,  strcspn($_SERVER['PHP_SELF'], "\n\r")), ENT_QUOTES);
header('Content-type: text/html; charset=utf-8');
ini_set('session.gc_maxlifetime', 7776000);
ini_set('session.cookie_lifetime', 7776000);
session_set_cookie_params(7776000);
session_start();
$user = isset($_SESSION['osm_user']) ? $_SESSION['osm_user'] : DEFAULT_USER;

$action = isset($_REQUEST['action']) ? $_REQUEST['action'] : '';
if( $action == 'login' ) {
    try {
         $oauth = new OAuth(CLIENT_ID,CLIENT_SECRET,OAUTH_SIG_METHOD_HMACSHA1,OAUTH_AUTH_TYPE_URI);
         $request_token_info = $oauth->getRequestToken(REQUEST_ENDPOINT);
         $_SESSION['secret'] = $request_token_info['oauth_token_secret'];
         header('Location: '.AUTHORIZATION_ENDPOINT."?oauth_token=".$request_token_info['oauth_token']);
    } catch(OAuthException $E) {
         print_r($E);
    }
    exit;
} elseif( $action == 'callback' ) {
    if(!isset($_GET['oauth_token'])) {
        echo "Error! There is no OAuth token!";
        exit;
    }

    if(!isset($_SESSION['secret'])) {
        echo "Error! There is no OAuth secret!";
        exit;
    }
    try {
        $oauth = new OAuth(CLIENT_ID, CLIENT_SECRET, OAUTH_SIG_METHOD_HMACSHA1, OAUTH_AUTH_TYPE_URI);
        $oauth->enableDebug();

        $oauth->setToken($_GET['oauth_token'], $_SESSION['secret']);
        $access_token_info = $oauth->getAccessToken(TOKEN_ENDPOINT);

        $token = strval($access_token_info['oauth_token']);
        $secret = strval($access_token_info['oauth_token_secret']);

        $oauth->setToken($token, $secret);

        /// получаем данные пользователя через /api/0.6/user/details
        $oauth->fetch(OSM_API."user/details");
        $user_details = $oauth->getLastResponse();

        // парсим ответ, получаем имя осмопользователя и его id
        $xml = simplexml_load_string($user_details);       
        $_SESSION['osm_user'] = strval($xml->user['display_name']);

        // Переход на станицу успеха
        header("Location: ".$php_self);
    } catch(OAuthException $E) {
        echo("Exception:\n");
        print_r($E);
    }
    exit;
} elseif( $action == 'logout' ) {
    unset($_SESSION['osm_user']);
    $user = '';
}

$db = new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_DATABASE);
$db->set_charset('utf8');

if( $action == 'comment' ) {
    if( $user && isset($_POST['comment']) && isset($_REQUEST['statid']) ) {
        $id = $_REQUEST['statid'];
        if( !preg_match('/^\d+$/', $id) ) {
            echo 'Incorrect id value: '.$id;
            exit;
        }
        $good = isset($_REQUEST['good']) ? $_REQUEST['good'] : '';
        if( !preg_match('/^[01]?$/', $good) ) {
            echo 'Incorrect quality value: '.$good;
            exit;
        }
        if( $good == '' ) $good = 'null';
        if( !$db->query("update ".DB_TABLE." set good = $good, comment = '".$db->escape_string($_POST['comment'])."', checked_by = '".$db->escape_string($user)."' where stat_id = $id") ) {
            echo 'Error updating database: '.$db->error;
            exit;
        }
        if( $handle = @fopen(LOG_FILE, 'a') ) {
            $res = $db->query('select user_name, map_date from '.DB_TABLE.' where stat_id = '.$id);
            $row = $res && $res->num_rows > 0 ? $res->fetch_assoc() : array('user_name' => '???', 'map_date' => '???');
            $time = localtime();
            fwrite($handle, sprintf("В %02d:%02d %s %s правку %s от %s (№%d): %s\n", $time[2], $time[1], $user, $good == '0' ? 'забраковал' : ($good == '1' ? 'одобрил' : 'прокомментировал'), $row['user_name'], $row['map_date'], $id, str_replace("\n", '\n', $_POST['comment'])));
            fclose($handle);
        }

        header("Location: ".$php_self);
        exit;
    }
} elseif( $action == 'rss' ) {
    $result = $db->query("select * from ".DB_TABLE." where object_count >= ".OBJ_LIMIT." and map_date < curdate() order by stat_id desc limit 15");
    header('Content-type: application/rss+xml; charset=utf-8');
    $url = 'http://'.$_SERVER['HTTP_HOST'].$php_self;
    print <<<"EOT"
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
\t<title>Вахтёр OpenStreetMap</title>
\t<description>Лента записей системы &amp;laquo;Вахтёр&amp;raquo;</description>
\t<link>$url</link>
\t<ttl>360</ttl>

EOT;
$months = array('января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря', 'мартобря');
date_default_timezone_set('UTC');
while( $row = $result->fetch_assoc() ) {
    print "\t<item>\n";
    $verb = $row['good'] == 1 ? 'мапил' : 'попортил';
    print "\t\t<title>".htmlspecialchars($row['user_name'])." $verb ".htmlspecialchars($row['location'])."</title>\n";
    print "\t\t<link>http://www.openstreetmap.org/browse/changeset/${row['changeset']}</link>\n";
    $date = strtotime($row['map_date']) + $row['stat_id'];
    $date_str = date(DATE_RSS, $date);
    print "\t\t<pubDate>$date_str</pubDate>\n";
    $datep = localtime($date);
    $desc = $datep[3].' '.$months[$datep[4]].' пользователь '.htmlspecialchars($row['user_name']).' <a href="http://www.openstreetmap.org/browse/changeset/'.$row['changeset'].'">нарисовал</a> '.$row['object_count'].' домиков в <a href="'.htmlspecialchars(sprintf(MAP_URL, $row['lat'], $row['lon'])).'">'.htmlspecialchars($row['location']).'</a>, где отсутствуют детальные снимки Bing.';
    if( $row['checked_by'] ) {
        $desc .= '<br><br>'.htmlspecialchars($row['checked_by']).' '.(is_null($row['good']) ? 'заметил' : ($row['good'] == 1 ? 'одобрил' : ($row['good'] == 0 ? 'обеспокоен' : 'сломал базу'))).': '.str_replace("\n", '<br>', htmlspecialchars($row['comment']));
    }
    print "\t\t<description>".htmlspecialchars($desc)."</description>\n";
    print "\t</item>\n";
}
print "</channel>\n</rss>";
exit;
}

$uid = isset($_REQUEST['uid']) ? $_REQUEST['uid'] : '';
$uidsql = preg_match('/^\d+$/', $uid) ? ' and user_id = '.$uid : '';

$startid = isset($_REQUEST['top']) ? $_REQUEST['top'] : '';
$topsql = preg_match('/^\d+$/', $startid) ? ' and stat_id <= '.$startid : '';

$objlimit = $uid ? 0 : OBJ_LIMIT;

# выбираем пользователей, однозначно плохих или хороших
$users_good = array();
$users_bad = array();
$res = $db->query('select user_id, good from '.DB_TABLE.' group by user_id, good having good is not null');
if( $res ) {
    while( $row = $res->fetch_array() ) {
        if( $row[1] == 0 ) {
            if( ($i = array_search($row[0], $users_good)) !== FALSE )
                array_splice($users_good, $i, 1);
            else
                $users_bad[] = $row[0];
        } elseif( $row[1] == 1 ) {
            if( ($i = array_search($row[0], $users_bad)) !== FALSE )
                array_splice($users_bad, $i, 1);
            else
                $users_good[] = $row[0];
        }
    }
}

$result = $db->query("select * from ".DB_TABLE." where object_count >= $objlimit $uidsql$topsql order by stat_id desc limit ".(PAGE_SIZE + 1));
?>
<html>
<head>
<title>Вахтёр OpenStreetMap</title>
<link rel="alternate" type="application/rss+xml" title="Лента RSS" href="<?=$_SERVER['PHP_SELF']?>?action=rss" />
<style>
* {
    font-family: Verdana, Arial, sans-serif;
    font-size: 10pt;
}
body {
    background: white;
    color: black;
}
body>p {
    max-width: 750px;
}
h1 {
    font-size: 14pt;
}
table {
    border-spacing: 0;
    border-collapse: collapse;
    margin-top: 2em;
}
th {
    background: #eee;
    text-align: center;
    font-weight: bold;
}
td {
    padding: 6px 4px;
}
.number {
    text-align: right;
    padding-right: 1em;
}
.good, .ugood { background: #7f7; }
.bad, .ubad { background: #f77; }
.nocomment {
    color: #777;
}
.build {
    display: inline-block;
    padding: 4px 4px;
    border: 1px solid #bbb;
    cursor: default;
}
.b-b { background: inherit; border-color: transparent; cursor: pointer; }
.b-0 { background: #fbb; }
.b-1 { background: #bfb; }
.b-2 { background: #ffa; }
textarea {
    width: 100%;
    height: 3em;
    margin: 2px 0;
}
</style>
<script>
function cb(cnt, value) {
    for( i = 0; i <= 2; i++ ) {
        document.getElementById('b'+cnt+''+i).className = 'build b-' + (i == value ? value : 'b');
    }
    document.getElementById('good'+cnt).value = value > 1 ? '' : value;
    document.getElementById('comment'+cnt).focus();
}
</script>
</head>
<body>
<h1>Вахтёр OpenStreetMap</h1>
<p>В эту таблицу записаны случаи рисования домов в местах, где отсутствует покрытие качественными снимками Bing. Если человек загрузил несколько ченджсетов, отражены данные лишь по первому (но количество объектов суммируется). Большое количество нарисованных домов может означать импорт, рисование по памяти или &mdash; что мы и пытаемся отловить &mdash; рисование по чужим снимкам или обводку чужих карт. Пользователи OpenStreetMap могут <? if(!$user): ?><a href="<?=$php_self?>?action=login"><? endif; ?>залогиниться<? if(!$user): ?></a><? else: ?> (вы <?=$user ?>, <a href="<?=$php_self?>?action=logout">выйти</a>)<? endif; ?> и оставлять комментарии насчёт правок, равно как и определять, &laquo;хорошие&raquo; они или &laquo;плохие&raquo;. Если обнаружите нарушение наших условий участия, напишите автору. Если ответ вас неприятно удивил, обращайтесь в тему &laquo;<a href="http://forum.openstreetmap.org/viewtopic.php?id=6129" target="_blank">откаты правок</a>&raquo; или <a href="mailto:board@openstreetmap.ru">на почту Совету</a>.</p>
<table>
<tr>
    <th>Дата</th>
    <th>Кто</th>
    <th>Сколько</th>
    <th>Где</th>
    <th>Комментарий</th>
</tr>
<? $cnt = PAGE_SIZE; while( $cnt --> 0 && ($row = $result->fetch_assoc()) ): ?>
<tr class="<?=$row['good'] == 1 ? 'good' : ($row['good'] == 0 && !is_null($row['good']) ? 'bad' : '')?>">
    <td><?=$row['map_date'] ?></td>
    <td><span class="<?=in_array($row['user_id'], $users_good) ? 'ugood' : (in_array($row['user_id'], $users_bad) ? 'ubad' : '')?>"><a href="http://www.openstreetmap.org/browse/changeset/<?=rawurlencode($row['changeset']) ?>" target="_blank"><?=htmlspecialchars($row['user_name']) ?></a></span> <a href="<?=$php_self ?>?uid=<?=$row['user_id'] ?>">[Ф]</a></td>
    <td class="number"><?=$row['object_count'] ?></td>
    <td><a href="<?=sprintf(MAP_URL, $row['lat'], $row['lon']) ?>" target="_blank"><?=htmlspecialchars($row['location']) ?></a> <a href="http://osm.sbin.ru/ov3/map#zoom=14&lat=<?=$row['lat']?>&lon=<?=$row['lon']?>" target="_blank" style="color: #bbb; font-size: 8pt;">(ov3?)</a></td>
    <td>
        <span id="c<?=$cnt?>"><? if( $row['checked_by'] ): ?>
        <?=htmlspecialchars($row['checked_by'])?> <?=is_null($row['good']) ? 'заметил' : ($row['good'] == 1 ? 'одобрил' : ($row['good'] == 0 ? 'обеспокоен' : 'сломал базу'))?>: <?=str_replace("\n", '<br>', htmlspecialchars($row['comment'])) ?>
        <? else: ?><span class="nocomment">Нет</span>
        <? endif; ?>
        <? if($user): ?>
        (<a href="#" onclick="javascript:document.getElementById('f<?=$cnt?>').style.display='block';document.getElementById('c<?=$cnt?>').style.display='none';document.getElementById('comment<?=$cnt?>').focus();return false;">Изменить</a>)</span>
        <div id="f<?=$cnt?>" style="display: none;">
        <form action="<?=$php_self?>" method="post">
            <input type="hidden" name="action" value="comment">
            <input type="hidden" name="statid" value="<?=$row['stat_id']?>">
            <input type="hidden" name="good" id="good<?=$cnt?>" value="">
            <div>Эти дома: <span id="b<?=$cnt?>2" class="build b-2" onclick="javascript:cb('<?=$cnt?>',2);">ХЗ</span><span id="b<?=$cnt?>0" class="build b-b" onclick="javascript:cb('<?=$cnt?>',0);">нужно выпилить</span><span id="b<?=$cnt?>1" class="build b-b" onclick="javascript:cb('<?=$cnt?>',1);">из допустимого источника</span></div>
            <div><textarea name="comment" id="comment<?=$cnt?>"></textarea></div>
            <div><input type="submit" value="Сохранить"></div>
        </form>
    </div>
    <? else: ?></span><? endif; ?>
</td>
</tr>
<? endwhile; ?>
</table>
<? if( $row = $result->fetch_assoc() ): ?>
<p><a href="<?=$php_self ?>?top=<?=$row['stat_id'] ?><?=$uid ? '&uid='.$uid : '' ?>">Ранее &raquo;</a></p>
<? endif; ?>
</body>
</html>
