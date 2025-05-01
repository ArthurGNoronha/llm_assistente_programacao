import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert'; // Para jsonEncode, jsonDecode, utf8 e LineSplitter
import 'dart:async'; // Para StreamSubscription
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_markdown/flutter_markdown.dart'; // Importa o pacote Markdown
import 'package:markdown/markdown.dart' as md; // Importa o pacote markdown para md.Text

// --- ChatMessage Class (sem alterações) ---
class ChatMessage {
  final String text;
  final bool isUser;

  ChatMessage({required this.text, required this.isUser});
}

// --- main Function (sem alterações) ---
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(ProgrammingAssistantApp());
}

// --- ProgrammingAssistantApp StatefulWidget (sem alterações na estrutura) ---
class ProgrammingAssistantApp extends StatefulWidget {
  ProgrammingAssistantApp({super.key});

  @override
  State<ProgrammingAssistantApp> createState() => _ProgrammingAssistantAppState();
}

// --- _ProgrammingAssistantAppState (sem alterações na estrutura) ---
class _ProgrammingAssistantAppState extends State<ProgrammingAssistantApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _changeTheme(ThemeMode themeMode) {
    setState(() {
      _themeMode = themeMode;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Assistente de Programação',
       theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: Colors.deepPurple,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        cardTheme: CardTheme(elevation: 1, margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),),),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        cardTheme: CardTheme(elevation: 1, margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),),),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      debugShowCheckedModeBanner: false,
      home: ChatScreen(
        currentThemeMode: _themeMode,
        onThemeChanged: _changeTheme,
      ),
    );
  }
}


// --- ChatScreen StatefulWidget (sem alterações na estrutura) ---
class ChatScreen extends StatefulWidget {
  final ThemeMode currentThemeMode;
  final Function(ThemeMode) onThemeChanged;

  const ChatScreen({
    super.key,
    required this.currentThemeMode,
    required this.onThemeChanged,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

// --- _ChatScreenState (principais modificações aqui) ---
class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  String? _apiKey;
  final ScrollController _scrollController = ScrollController();
  // Para gerenciar a subscrição ao stream da API
  StreamSubscription? _streamSubscription;
  // Cliente HTTP para manter a conexão aberta durante o stream
  final http.Client _client = http.Client();

  @override
  void initState() {
    super.initState();
    _loadApiKey();
     WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
           _addInitialMessage();
        }
     });
  }

  @override
  void dispose() {
     _scrollController.dispose();
     _controller.dispose();
     _streamSubscription?.cancel(); // Cancela o stream se ainda estiver ativo
     _client.close(); // Fecha o cliente HTTP
    super.dispose();
  }

   void _addInitialMessage() {
     if (mounted) {
      setState(() {
        _messages.add(ChatMessage(
          text: "Olá! Sou seu assistente de programação. Faça sua pergunta sobre sintaxe ou lógica. Pedirei exemplos de código quando relevante.",
          isUser: false,
        ));
      });
    }
   }

   void _loadApiKey() {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey != null && apiKey.isNotEmpty) {
      _apiKey = apiKey;
    } else {
       if (mounted && _messages.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if(mounted) { _addMessage("...", isUser: false); } // Placeholder antes do erro
            Future.delayed(const Duration(milliseconds: 50), () {
               if(mounted) { _updateLastMessage("Erro: API Key não encontrada no arquivo .env. Por favor, configure-o."); }
            });
          });
       }
    }
  }

  // Adiciona uma nova mensagem à lista
  void _addMessage(String text, {required bool isUser}) {
     if(mounted) {
       setState(() {
        _messages.add(ChatMessage(text: text, isUser: isUser));
      });
      Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);
     }
  }

  // Atualiza o texto da *última* mensagem na lista (usado para streaming)
  void _updateLastMessage(String text) {
    if (mounted && _messages.isNotEmpty) {
      setState(() {
        // Cria um novo objeto ChatMessage para garantir a atualização do estado
        _messages[_messages.length - 1] = ChatMessage(text: text, isUser: false);
      });
       Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);
    }
  }

  // Adiciona texto incrementalmente à última mensagem (usado para streaming)
   void _appendTokenToLastMessage(String token) {
     if (mounted && _messages.isNotEmpty && !_messages.last.isUser) {
       setState(() {
         _messages[_messages.length - 1] = ChatMessage(
           text: _messages.last.text + token,
           isUser: false
         );
       });
       // Rolar apenas se estiver perto do fim para não atrapalhar leitura
       if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 50) {
            Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);
       }
     }
   }

 void _scrollToBottom() {
    if (_scrollController.hasClients) {
       _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
 }

 // *** FUNÇÃO MODIFICADA PARA STREAMING ***
 Future<void> _sendMessage() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _isLoading) {
      return;
    }

    if (_apiKey == null || _apiKey!.isEmpty) {
       _addMessage("...", isUser: false); // Placeholder antes do erro
       Future.delayed(const Duration(milliseconds: 50), () {
         _updateLastMessage("Erro: API Key não configurada corretamente.");
       });
      return;
    }

    // Cancela qualquer stream anterior antes de iniciar um novo
    await _streamSubscription?.cancel();

    _controller.clear();
    _addMessage(query, isUser: true); // Adiciona pergunta do usuário
    _addMessage("...", isUser: false); // Adiciona placeholder para resposta da IA

    setState(() {
      _isLoading = true;
    });

    // URL para STREAMING do Gemini
    final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:streamGenerateContent?key=$_apiKey&alt=sse');

    final body = jsonEncode({
      "contents": [
        {
          "parts": [
             // *** PROMPT ATUALIZADO ***
            {"text": "Você é um assistente prestativo para programadores iniciantes. Responda a seguinte dúvida sobre programação de forma clara e concisa, explicando sintaxe ou lógica. Use markdown para formatação (como negrito, listas) e **inclua exemplos de código curtos e claros em blocos de markdown ``` ``` sempre que for útil** para ilustrar a resposta:"},
            {"text": query}
          ]
        }
      ],
      // Configurações (semelhantes, mas `responseMimeType` não é usado diretamente no stream)
      "generationConfig": {"temperature": 0.7, "topK": 1, "topP": 1, "maxOutputTokens": 2048},
      "safetySettings": [{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"}, {"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_MEDIUM_AND_ABOVE"}, {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"}, {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"}]
    });

    try {
      final request = http.Request('POST', url);
      request.headers['Content-Type'] = 'application/json';
      request.body = body;

      // Usa o cliente persistente para enviar a requisição
      final response = await _client.send(request);

      if (response.statusCode == 200) {
        // Limpa o placeholder "..." da última mensagem
        _updateLastMessage("");

        // Escuta o stream de resposta
        _streamSubscription = response.stream
            .transform(utf8.decoder) // Decodifica bytes para String
            .transform(const LineSplitter()) // Divide em linhas
            .listen(
          (line) {
            // Processa linhas de eventos SSE (Server-Sent Events)
            if (line.startsWith('data: ')) {
              final jsonString = line.substring(6);
              if (jsonString.trim().isNotEmpty) {
                 try {
                  final decodedChunk = jsonDecode(jsonString);
                  // Extrai o texto do chunk (estrutura pode variar um pouco)
                  final textPart = decodedChunk['candidates']?[0]?['content']?['parts']?[0]?['text'];
                  if (textPart != null) {
                    // Adiciona o pedaço de texto à última mensagem
                    _appendTokenToLastMessage(textPart);
                  }
                 } catch (e) {
                    print("Erro ao decodificar chunk JSON: $e - Chunk: $jsonString");
                    // Poderia adicionar uma mensagem de erro parcial se desejado
                 }
              }
            } else if (line.trim().isEmpty) {
               // Linhas vazias separam eventos SSE, podem ser ignoradas aqui.
            } else {
               print("Linha inesperada no stream: $line");
            }
          },
          onDone: () { // Stream concluído com sucesso
            if (mounted) {
              setState(() { _isLoading = false; });
               // Garante scroll final
               Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
            }
          },
          onError: (error) { // Erro durante o stream
            print("Erro no stream: $error");
             if (mounted) {
               _appendTokenToLastMessage("\n\nErro durante a recepção da resposta: $error");
               setState(() { _isLoading = false; });
             }
          },
          cancelOnError: true, // Cancela a subscrição em caso de erro
        );
      } else { // Erro na requisição inicial (não 200 OK)
        final errorBody = await response.stream.bytesToString(); // Lê corpo do erro
         final decodedError = jsonDecode(errorBody);
         final errorMessage = decodedError['error']?['message'] ?? 'Erro desconhecido na API.';
         _updateLastMessage("Erro ${response.statusCode}: $errorMessage");
         if (mounted) { setState(() { _isLoading = false; }); }
      }
    } catch (e) { // Erro ao enviar a requisição (ex: rede)
       print("Erro ao enviar requisição de stream: $e");
       _updateLastMessage("Erro de conexão: $e");
        if (mounted) { setState(() { _isLoading = false; }); }
    }
  }


 // --- build Method (AppBar com botão de tema) ---
 @override
  Widget build(BuildContext context) {
    final isDarkMode = widget.currentThemeMode == ThemeMode.dark ||
                       (widget.currentThemeMode == ThemeMode.system &&
                        MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assistente de Programação'),
        actions: [
          IconButton(
            icon: Icon(isDarkMode ? Icons.light_mode : Icons.dark_mode),
            tooltip: 'Alterar Tema',
            onPressed: () {
              widget.onThemeChanged(isDarkMode ? ThemeMode.light : ThemeMode.dark);
            },
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(8.0),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageBubble(message); // Chamada não muda
              },
            ),
          ),
          _buildInputArea(), // Chamada não muda
        ],
      ),
    );
  }


  // *** WIDGET DO BALÃO DE MENSAGEM MODIFICADO PARA MARKDOWN ***
  Widget _buildMessageBubble(ChatMessage message) {
    final bool isUser = message.isUser;
    final theme = Theme.of(context);
    final bubbleColor = isUser ? theme.colorScheme.primaryContainer : theme.colorScheme.secondaryContainer;
    // Adapta a cor do texto para markdown no modo escuro
    final markdownStyleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
       p: theme.textTheme.bodyMedium?.copyWith(
          color: isUser ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSecondaryContainer
       ),
       code: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace', // Fonte monoespaçada para código
           // Cor de fundo sutil para blocos de código
          backgroundColor: theme.colorScheme.onSurface.withOpacity(0.1),
          color: isUser ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSecondaryContainer
       ),
       // Adapte outras tags (h1, h2, blockquote, etc.) se necessário
    );


    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Card(
        color: bubbleColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
          // *** USA MARKDOWN PARA ASSISTENTE, SELECTABLE TEXT PARA USUÁRIO ***
          child: isUser
              ? SelectableText(
                  message.text,
                  style: TextStyle(color: theme.colorScheme.onPrimaryContainer)
                )
              // *** USA SelectionArea PARA PERMITIR SELEÇÃO NO MARKDOWN ***
              : SelectionArea(
                  child: MarkdownBody(
                     data: message.text.isEmpty ? "..." : message.text, // Mostra "..." se vazio
                     selectable: false, // SelectionArea cuida da seleção
                     styleSheet: markdownStyleSheet,
                      // Adiciona padding customizado para blocos de código se necessário
                      // builders: { 'code': CodeElementBuilder(), },
                  ),
              ),
        ),
      ),
    );
  }

 // --- _buildInputArea Method (sem alterações funcionais) ---
 Widget _buildInputArea() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Digite sua dúvida...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20.0), borderSide: BorderSide.none,),
                filled: true,
                fillColor: theme.colorScheme.surfaceVariant.withOpacity(0.6),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
              enabled: !_isLoading,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          _isLoading
              ? Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: theme.colorScheme.primary))
              )
              : IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                  tooltip: 'Enviar Pergunta',
                  style: IconButton.styleFrom(backgroundColor: theme.colorScheme.primary, foregroundColor: theme.colorScheme.onPrimary,),
                ),
        ],
      ),
    );
 }

}

class CodeElementBuilder extends MarkdownElementBuilder {
  @override
  Widget visitText(md.Text text, TextStyle? preferredStyle) {
    // Estilos customizados para texto dentro de blocos de código
    return Text(
      text.text,
      style: preferredStyle?.copyWith(
        fontFamily: 'monospace',
        // Outros estilos se necessário
      ),
    );
  }
}