
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';

final FlutterLocalNotificationsPlugin notificacoes =
    FlutterLocalNotificationsPlugin();

const int idNotificacaoTemporizador = 1001;

// Favoritos da sessão atual: Supabase para contas, armazenamento local para visitantes.
final Set<int> receitasFavoritas = {};
const String chaveModoVisitante = 'modo_visitante';
const String chaveFavoritosVisitante = 'receitas_favoritas_visitante';

Future<void> definirModoVisitante(bool ativo) async {
  final preferencias = await SharedPreferences.getInstance();
  await preferencias.setBool(chaveModoVisitante, ativo);
}

Future<bool> carregarModoVisitante() async {
  final preferencias = await SharedPreferences.getInstance();
  return preferencias.getBool(chaveModoVisitante) ?? false;
}

Future<void> carregarFavoritos() async {
  final usuario = supabase.auth.currentUser;
  final Set<int> novosFavoritos = {};

  if (usuario != null) {
    final dados = await supabase
        .from('receita_favorita')
        .select('id_receita')
        .eq('id_usuario', usuario.id);
    for (final item in dados) {
      final id = item['id_receita'];
      if (id is int) novosFavoritos.add(id);
    }
  } else {
    final preferencias = await SharedPreferences.getInstance();
    var ids = preferencias.getStringList(chaveFavoritosVisitante);
    if (ids == null) {
      // Preserva os favoritos locais de versões anteriores como favoritos de visitante.
      ids = preferencias.getStringList('receitas_favoritas') ?? <String>[];
      await preferencias.setStringList(chaveFavoritosVisitante, ids);
      await preferencias.remove('receitas_favoritas');
    }
    novosFavoritos.addAll(ids.map(int.tryParse).whereType<int>());
  }

  // Evita misturar listas se a conta mudar durante a consulta.
  if (supabase.auth.currentUser?.id != usuario?.id) return;
  receitasFavoritas
    ..clear()
    ..addAll(novosFavoritos);
}

Future<void> alternarFavorito(int idReceita) async {
  final usuario = supabase.auth.currentUser;
  final jaFavorita = receitasFavoritas.contains(idReceita);

  if (usuario != null) {
    if (jaFavorita) {
      await supabase
          .from('receita_favorita')
          .delete()
          .eq('id_usuario', usuario.id)
          .eq('id_receita', idReceita);
    } else {
      await supabase.from('receita_favorita').insert({
        'id_usuario': usuario.id,
        'id_receita': idReceita,
      });
    }
  } else {
    final preferencias = await SharedPreferences.getInstance();
    final ids = Set<int>.from(receitasFavoritas);
    if (jaFavorita) {
      ids.remove(idReceita);
    } else {
      ids.add(idReceita);
    }
    await preferencias.setStringList(
      chaveFavoritosVisitante,
      ids.map((id) => id.toString()).toList(),
    );
  }

  if (supabase.auth.currentUser?.id != usuario?.id) return;
  if (jaFavorita) {
    receitasFavoritas.remove(idReceita);
  } else {
    receitasFavoritas.add(idReceita);
  }
}

Future<void> configurarNotificacoes() async {
  tzdata.initializeTimeZones();

  const androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const configuracoes = InitializationSettings(
    android: androidSettings,
  );

  await notificacoes.initialize(
    settings: configuracoes,
  );

  await notificacoes
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> agendarNotificacao(
  String nomeReceita,
  int segundos,
) async {
  if (segundos <= 0) return;

  await cancelarNotificacao();

  const android = AndroidNotificationDetails(
    'temporizador_receitas',
    'Temporizador de receitas',
    channelDescription: 'Avisos do temporizador de preparo.',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
  );

  await notificacoes.zonedSchedule(
    id: idNotificacaoTemporizador,
    title: 'Tempo encerrado!',
    body: 'O temporizador de $nomeReceita terminou.',
    scheduledDate: tz.TZDateTime.now(tz.local).add(
      Duration(seconds: segundos),
    ),
    notificationDetails: const NotificationDetails(
      android: android,
    ),
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
  );
}

Future<void> cancelarNotificacao() async {
  await notificacoes.cancel(id: idNotificacaoTemporizador);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await configurarNotificacoes();
  await dotenv.load(fileName: '.env');

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    publishableKey: dotenv.env['SUPABASE_PUBLISHABLE_KEY']!,
  );

  runApp(const MyApp());
}

final supabase = Supabase.instance.client;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Receitas',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
        ),
        useMaterial3: true,
      ),
      home: const TelaAutenticacao(),
    );
  }
}


// CONTROLE DE AUTENTICACAO: MOSTRA LOGIN OU APLICATIVO
class TelaAutenticacao extends StatelessWidget {
  const TelaAutenticacao({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final sessao = supabase.auth.currentSession;

        if (sessao != null) {
          return const TelaReceitas();
        }

        return FutureBuilder<bool>(
          future: carregarModoVisitante(),
          builder: (context, visitanteSnapshot) {
            if (visitanteSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (visitanteSnapshot.data == true) {
              return const TelaReceitas();
            }

            return const TelaLogin();
          },
        );
      },
    );
  }
}

// TELA EXIBIDA APOS CADASTRO COM CONFIRMACAO POR E-MAIL
class TelaConfirmacaoEmail extends StatelessWidget {
  final String email;

  const TelaConfirmacaoEmail({super.key, required this.email});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.deepOrange.shade50,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Card(
              elevation: 4,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const CircleAvatar(
                      radius: 42,
                      backgroundColor: Colors.green,
                      child: Icon(
                        Icons.mark_email_read_outlined,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Confira seu e-mail!',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Sua conta foi criada. Enviamos um e-mail de confirmação '
                      'para o endereço informado. Abra a mensagem e confirme '
                      'seu e-mail antes de fazer login.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, height: 1.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      email,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.deepOrange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) => const TelaLogin(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Voltar para o login'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepOrange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// TELA DE LOGIN E CADASTRO
class TelaLogin extends StatefulWidget {
  const TelaLogin({super.key});

  @override
  State<TelaLogin> createState() => _TelaLoginState();
}

class _TelaLoginState extends State<TelaLogin> {
  final formKey = GlobalKey<FormState>();
  final nomeController = TextEditingController();
  final emailController = TextEditingController();
  final senhaController = TextEditingController();

  bool modoCadastro = false;
  bool mostrarSenha = false;
  bool carregando = false;

  @override
  void dispose() {
    nomeController.dispose();
    emailController.dispose();
    senhaController.dispose();
    super.dispose();
  }

  Future<void> autenticar() async {
    if (!formKey.currentState!.validate()) return;

    setState(() => carregando = true);

    try {
      if (modoCadastro) {
        final resposta = await supabase.auth.signUp(
          email: emailController.text.trim(),
          password: senhaController.text,
          data: {
            'nome': nomeController.text.trim(),
          },
        );

        if (!mounted) return;

        if (resposta.session == null) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => TelaConfirmacaoEmail(
                email: emailController.text.trim(),
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Conta criada com sucesso!')),
          );
        }
      } else {
        await supabase.auth.signInWithPassword(
          email: emailController.text.trim(),
          password: senhaController.text,
        );
        await definirModoVisitante(false);
        await carregarFavoritos();

        if (!mounted) return;

        // Abre a tela de receitas imediatamente após o login bem-sucedido.
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => const TelaReceitas(),
          ),
          (route) => false,
        );
      }
    } on AuthException catch (erro) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(erro.message)),
      );
    } catch (erro) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ocorreu um erro: $erro')),
      );
    } finally {
      if (mounted) setState(() => carregando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.deepOrange.shade50,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Card(
              elevation: 4,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CircleAvatar(
                        radius: 38,
                        backgroundColor: Colors.deepOrange,
                        child: Icon(
                          Icons.restaurant_menu,
                          color: Colors.white,
                          size: 42,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        modoCadastro ? 'Crie sua conta' : 'Bem-vindo!',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        modoCadastro
                            ? 'Cadastre-se para acessar suas receitas.'
                            : 'Entre para continuar para suas receitas.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 28),
                      if (modoCadastro) ...[
                        TextFormField(
                          controller: nomeController,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Nome',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                          validator: (valor) {
                            if (modoCadastro &&
                                (valor == null || valor.trim().isEmpty)) {
                              return 'Informe seu nome.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'E-mail',
                          prefixIcon: Icon(Icons.email_outlined),
                          border: OutlineInputBorder(),
                        ),
                        validator: (valor) {
                          final email = valor?.trim() ?? '';
                          if (email.isEmpty || !email.contains('@')) {
                            return 'Informe um e-mail válido.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: senhaController,
                        obscureText: !mostrarSenha,
                        decoration: InputDecoration(
                          labelText: 'Senha',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () => mostrarSenha = !mostrarSenha,
                            ),
                            icon: Icon(
                              mostrarSenha
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            tooltip: mostrarSenha
                                ? 'Ocultar senha'
                                : 'Mostrar senha',
                          ),
                        ),
                        validator: (valor) {
                          if ((valor ?? '').length < 6) {
                            return 'A senha deve ter pelo menos 6 caracteres.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: carregando ? null : autenticar,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepOrange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: carregando
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  modoCadastro ? 'Criar conta' : 'Entrar',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: carregando
                            ? null
                            : () => setState(() {
                                  modoCadastro = !modoCadastro;
                                  formKey.currentState?.reset();
                                }),
                        child: Text(
                          modoCadastro
                              ? 'Já tem uma conta? Entrar'
                              : 'Não tem conta? Cadastre-se',
                        ),
                      ),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        onPressed: carregando
                            ? null
                            : () async {
                                await definirModoVisitante(true);
                                await carregarFavoritos();
                                if (!mounted) return;
                                Navigator.of(context).pushAndRemoveUntil(
                                  MaterialPageRoute(
                                    builder: (_) => const TelaReceitas(),
                                  ),
                                  (route) => false,
                                );
                              },
                        icon: const Icon(Icons.visibility_outlined),
                        label: const Text('Continuar como visitante'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


// TELA INICIAL COM PESQUISA


class TelaReceitas extends StatefulWidget {
  const TelaReceitas({super.key});

  @override
  State<TelaReceitas> createState() => _TelaReceitasState();
}

class _TelaReceitasState extends State<TelaReceitas> {
  late Future<List<Map<String, dynamic>>> receitasFuture;

  final TextEditingController pesquisaController =
      TextEditingController();

  String textoPesquisa = '';

  @override
  void initState() {
    super.initState();
    receitasFuture = carregarDadosIniciais();
  }

  @override
  void dispose() {
    pesquisaController.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> carregarDadosIniciais() async {
    await carregarFavoritos();
    return carregarReceitas();
  }

  Future<List<Map<String, dynamic>>> carregarReceitas() async {
    final dados = await supabase
        .from('receita')
        .select(
          'id_receita, nome, descricao, imagem_url, tempo_preparo_min',
        )
        .order('nome');

    return List<Map<String, dynamic>>.from(dados);
  }

  void atualizarReceitas() {
    setState(() {
      receitasFuture = carregarReceitas();
    });
  }

  void limparPesquisa() {
    pesquisaController.clear();

    setState(() {
      textoPesquisa = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Minhas Receitas',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Meu perfil',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TelaPerfil()),
              ).then((_) {
                if (mounted) setState(() {});
              });
            },
          ),
          IconButton(
            onPressed: () async {
              final confirmar = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(supabase.auth.currentSession == null ? 'Sair do modo visitante?' : 'Sair da conta?'),
                  content: Text(supabase.auth.currentSession == null ? 'Deseja voltar para a tela de login?' : 'Deseja encerrar sua sessão?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancelar'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Sair'),
                    ),
                  ],
                ),
              );
              if (confirmar == true) {
                if (supabase.auth.currentSession != null) {
                  await supabase.auth.signOut();
                }
                await definirModoVisitante(false);
                receitasFavoritas.clear();
                if (!mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const TelaLogin()),
                  (route) => false,
                );
              }
            },
            icon: const Icon(Icons.logout),
            tooltip: supabase.auth.currentSession == null ? 'Sair do modo visitante' : 'Sair da conta',
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const TelaFavoritos()),
              ).then((_) {
                if (mounted) setState(() {});
              });
            },
            icon: const Icon(Icons.favorite),
            tooltip: 'Ver favoritos',
          ),
          IconButton(
            onPressed: atualizarReceitas,
            icon: const Icon(Icons.refresh),
            tooltip: 'Atualizar receitas',
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: receitasFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Não foi possível carregar as receitas.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: atualizarReceitas,
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            );
          }

          final receitas = snapshot.data ?? [];
          final termo = textoPesquisa.trim().toLowerCase();

          final receitasFiltradas = receitas.where((receita) {
            final nome = receita['nome']?.toString() ?? '';
            final descricao =
                receita['descricao']?.toString() ?? '';

            return nome.toLowerCase().contains(termo) ||
                descricao.toLowerCase().contains(termo);
          }).toList();

          return Container(
            color: Colors.deepOrange.shade50.withValues(alpha: 0.25),
            child: Column(
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 1200,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        16,
                        16,
                        16,
                        8,
                      ),
                      child: TextField(
                        controller: pesquisaController,
                        onChanged: (valor) {
                          setState(() {
                            textoPesquisa = valor;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: 'Pesquisar receitas...',
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.deepOrange,
                          ),
                          suffixIcon: textoPesquisa.isNotEmpty
                              ? IconButton(
                                  onPressed: limparPesquisa,
                                  icon: const Icon(Icons.clear),
                                  tooltip: 'Limpar pesquisa',
                                )
                              : null,
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding:
                              const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 16,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.deepOrange.shade200,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Colors.deepOrange,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: receitasFiltradas.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  textoPesquisa.trim().isEmpty
                                      ? Icons.restaurant_menu
                                      : Icons.search_off,
                                  size: 56,
                                  color: Colors.deepOrange,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  textoPesquisa.trim().isEmpty
                                      ? 'Nenhuma receita cadastrada no Supabase.'
                                      : 'Nenhuma receita encontrada.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 16),
                                ),
                                if (textoPesquisa.trim().isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  TextButton(
                                    onPressed: limparPesquisa,
                                    child: const Text('Limpar pesquisa'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final largura = constraints.maxWidth;

                            final int colunas;

                            if (largura < 600) {
                              colunas = 1;
                            } else if (largura < 950) {
                              colunas = 2;
                            } else {
                              colunas = 3;
                            }

                            return Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1200,
                                ),
                                child: GridView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    24,
                                  ),
                                  itemCount: receitasFiltradas.length,
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: colunas,
                                    crossAxisSpacing: 16,
                                    mainAxisSpacing: 16,
                                    mainAxisExtent: 330,
                                  ),
                                  itemBuilder: (context, index) {
                                    final receita =
                                        receitasFiltradas[index];

                                    final nome =
                                        receita['nome']?.toString() ??
                                            'Receita sem nome';

                                    final descricao =
                                        receita['descricao']?.toString() ??
                                            '';

                                    final imagemUrl =
                                        receita['imagem_url']?.toString() ??
                                            '';

                                    final tempo =
                                        receita['tempo_preparo_min'];

                                    return Card(
                                      margin: EdgeInsets.zero,
                                      elevation: 2,
                                      clipBehavior: Clip.antiAlias,
                                      color: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14),
                                      ),
                                      child: InkWell(
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  DetalhesReceita(
                                                idReceita: receita[
                                                    'id_receita'] as int,
                                                nomeReceita: nome,
                                              ),
                                            ),
                                          );
                                        },
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            SizedBox(
                                              height: 155,
                                              width: double.infinity,
                                              child: imagemUrl.isNotEmpty
                                                  ? Image.network(
                                                      imagemUrl,
                                                      fit: BoxFit.cover,
                                                      errorBuilder: (
                                                        context,
                                                        error,
                                                        stackTrace,
                                                      ) {
                                                        return Container(
                                                          color: Colors
                                                              .orange.shade50,
                                                          child: const Center(
                                                            child: Icon(
                                                              Icons.restaurant,
                                                              size: 56,
                                                              color: Colors
                                                                  .deepOrange,
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    )
                                                  : Container(
                                                      color: Colors
                                                          .orange.shade50,
                                                      child: const Center(
                                                        child: Icon(
                                                          Icons.restaurant,
                                                          size: 56,
                                                          color: Colors
                                                              .deepOrange,
                                                        ),
                                                      ),
                                                    ),
                                            ),
                                            Expanded(
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.all(14),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            nome,
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: Theme.of(context)
                                                                .textTheme.titleMedium
                                                                ?.copyWith(fontWeight: FontWeight.bold),
                                                          ),
                                                        ),
                                                        IconButton(
                                                          visualDensity: VisualDensity.compact,
                                                          padding: EdgeInsets.zero,
                                                          constraints: const BoxConstraints(),
                                                          tooltip: receitasFavoritas.contains(receita['id_receita'] as int)
                                                              ? 'Remover dos favoritos'
                                                              : 'Adicionar aos favoritos',
                                                          onPressed: () async {
                                                            final id = receita['id_receita'] as int;
                                                            try {
                                                              await alternarFavorito(id);
                                                              if (mounted) setState(() {});
                                                            } catch (erro) {
                                                              if (!mounted) return;
                                                              ScaffoldMessenger.of(context).showSnackBar(
                                                                SnackBar(content: Text('Erro ao salvar favorito: $erro')),
                                                              );
                                                            }
                                                          },
                                                          icon: Icon(
                                                            receitasFavoritas.contains(receita['id_receita'] as int)
                                                                ? Icons.favorite
                                                                : Icons.favorite_border,
                                                            color: Colors.deepOrange,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Expanded(
                                                      child: Text(
                                                        descricao.isEmpty
                                                            ? 'Sem descrição cadastrada.'
                                                            : descricao,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: Colors
                                                              .grey.shade700,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 8),
                                                    Row(
                                                      children: [
                                                        const Icon(
                                                          Icons.schedule,
                                                          size: 18,
                                                          color: Colors
                                                              .deepOrange,
                                                        ),
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            tempo == null
                                                                ? 'Tempo não informado'
                                                                : '$tempo minutos',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 13,
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(width: 4),
                                                        const Text(
                                                          'Ver receita',
                                                          style: TextStyle(
                                                            color: Colors
                                                                .deepOrange,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize: 13,
                                                          ),
                                                        ),
                                                        const Icon(
                                                          Icons.chevron_right,
                                                          color: Colors
                                                              .deepOrange,
                                                          size: 20,
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}


// PERFIL DO USUÁRIO (dados do Supabase Auth)
class TelaPerfil extends StatefulWidget {
  const TelaPerfil({super.key});

  @override
  State<TelaPerfil> createState() => _TelaPerfilState();
}

class _TelaPerfilState extends State<TelaPerfil> {
  bool salvando = false;

  Future<void> editarNome() async {
    final usuario = supabase.auth.currentUser;
    if (usuario == null) return;

    final controller = TextEditingController(
      text: usuario.userMetadata?['nome']?.toString() ?? '',
    );
    final novoNome = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Editar nome'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nome',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              final nome = controller.text.trim();
              if (nome.isNotEmpty) Navigator.pop(dialogContext, nome);
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (novoNome == null || !mounted) return;

    setState(() => salvando = true);
    try {
      await supabase.auth.updateUser(
        UserAttributes(data: {
          ...?supabase.auth.currentUser?.userMetadata,
          'nome': novoNome,
        }),
      );
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nome atualizado com sucesso!')),
      );
    } catch (erro) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível atualizar o nome: $erro')),
      );
    } finally {
      if (mounted) setState(() => salvando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final usuario = supabase.auth.currentUser;
    final visitante = usuario == null;
    final nome = visitante
        ? 'Visitante'
        : (usuario.userMetadata?['nome']?.toString().trim().isNotEmpty == true
            ? usuario.userMetadata!['nome'].toString().trim()
            : 'Usuário');
    final email = usuario?.email ?? 'Não disponível no modo visitante';
    final criadoEm = usuario?.createdAt;
    final dataCadastro = criadoEm == null
        ? 'Não disponível'
        : (() {
            final data = DateTime.tryParse(criadoEm)?.toLocal();
            if (data == null) return 'Não disponível';
            return '${data.day.toString().padLeft(2, '0')}/'
                '${data.month.toString().padLeft(2, '0')}/${data.year}';
          })();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meu perfil'),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 12),
              const CircleAvatar(
                radius: 46,
                backgroundColor: Colors.deepOrange,
                child: Icon(Icons.person, size: 54, color: Colors.white),
              ),
              const SizedBox(height: 14),
              Text(
                nome,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                visitante ? 'Navegando como visitante' : 'Conta cadastrada',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Nome'),
                      subtitle: Text(nome),
                      trailing: visitante
                          ? null
                          : IconButton(
                              tooltip: 'Editar nome',
                              onPressed: salvando ? null : editarNome,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.email_outlined),
                      title: const Text('E-mail'),
                      subtitle: Text(email),
                    ),
                    if (!visitante) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.verified_user_outlined),
                        title: const Text('E-mail confirmado'),
                        subtitle: Text(usuario.emailConfirmedAt != null ? 'Sim' : 'Não'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.calendar_today_outlined),
                        title: const Text('Data de cadastro'),
                        subtitle: Text(dataCadastro),
                      ),
                    ],
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.favorite_outline),
                      title: const Text('Receitas favoritas'),
                      subtitle: Text('${receitasFavoritas.length} receitas'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const TelaFavoritos()),
                        ).then((_) {
                          if (mounted) setState(() {});
                        });
                      },
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
              if (salvando) const LinearProgressIndicator(),
              if (visitante) ...[
                const SizedBox(height: 20),
                const Text(
                  'Crie uma conta ou entre para sincronizar seus favoritos entre dispositivos. '
                  'Os favoritos de visitante continuam salvos apenas neste dispositivo.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    await definirModoVisitante(false);
                    receitasFavoritas.clear();
                    if (!mounted) return;
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const TelaLogin()),
                      (_) => false,
                    );
                  },
                  icon: const Icon(Icons.login),
                  label: const Text('Entrar ou criar conta'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// TELA DE RECEITAS FAVORITAS

class TelaFavoritos extends StatefulWidget {
  const TelaFavoritos({super.key});

  @override
  State<TelaFavoritos> createState() => _TelaFavoritosState();
}

class _TelaFavoritosState extends State<TelaFavoritos> {
  late Future<List<Map<String, dynamic>>> receitasFuture;

  @override
  void initState() {
    super.initState();
    receitasFuture = carregarReceitasFavoritas();
  }

  Future<List<Map<String, dynamic>>> carregarReceitasFavoritas() async {
    await carregarFavoritos();
    if (receitasFavoritas.isEmpty) return [];
    final dados = await supabase
        .from('receita')
        .select('id_receita, nome, descricao, imagem_url, tempo_preparo_min')
        .order('nome');
    return List<Map<String, dynamic>>.from(dados).where((receita) {
      final id = receita['id_receita'];
      return id is int && receitasFavoritas.contains(id);
    }).toList();
  }

  void atualizar() {
    setState(() => receitasFuture = carregarReceitasFavoritas());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas favoritas'),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: atualizar, icon: const Icon(Icons.refresh), tooltip: 'Atualizar'),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: receitasFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Não foi possível carregar os favoritos.'),
                    const SizedBox(height: 12),
                    ElevatedButton(onPressed: atualizar, child: const Text('Tentar novamente')),
                  ],
                ),
              ),
            );
          }
          final receitas = snapshot.data ?? [];
          if (receitas.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.favorite_border, size: 64, color: Colors.deepOrange),
                    const SizedBox(height: 12),
                    const Text('Você ainda não tem receitas favoritas.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    const Text('Toque no coração de uma receita para salvá-la aqui.', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Explorar receitas')),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: receitas.length,
            itemBuilder: (context, index) {
              final receita = receitas[index];
              final id = receita['id_receita'] as int;
              final nome = receita['nome']?.toString() ?? 'Receita sem nome';
              final descricao = receita['descricao']?.toString() ?? '';
              final imagemUrl = receita['imagem_url']?.toString() ?? '';
              final tempo = receita['tempo_preparo_min'];
              return Card(
                clipBehavior: Clip.antiAlias,
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(8),
                  leading: SizedBox(
                    width: 76,
                    height: 76,
                    child: imagemUrl.isEmpty
                        ? const Icon(Icons.restaurant, size: 40, color: Colors.deepOrange)
                        : Image.network(imagemUrl, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.restaurant, size: 40, color: Colors.deepOrange)),
                  ),
                  title: Text(nome, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [if (descricao.isNotEmpty) descricao, if (tempo != null) '$tempo minutos'].join('\n'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Remover dos favoritos',
                    icon: const Icon(Icons.favorite, color: Colors.deepOrange),
                    onPressed: () async {
                      try {
                        await alternarFavorito(id);
                      } catch (erro) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Erro ao remover favorito: $erro')),
                        );
                        return;
                      }
                      if (!mounted) return;

                      setState(() {
                        receitasFuture = Future.value(
                          receitas
                              .where((item) => item['id_receita'] != id)
                              .toList(),
                        );
                      });
                    },
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => DetalhesReceita(idReceita: id, nomeReceita: nome),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}


// DETALHES DA RECEITA

class DetalhesReceita extends StatefulWidget {
  final int idReceita;
  final String nomeReceita;

  const DetalhesReceita({
    super.key,
    required this.idReceita,
    required this.nomeReceita,
  });

  @override
  State<DetalhesReceita> createState() => _DetalhesReceitaState();
}

class _DetalhesReceitaState extends State<DetalhesReceita> {
  late Future<Map<String, dynamic>> dadosFuture;

  @override
  void initState() {
    super.initState();
    dadosFuture = carregarDetalhes();
  }

  Future<Map<String, dynamic>> carregarDetalhes() async {
    final receita = await supabase
        .from('receita')
        .select()
        .eq('id_receita', widget.idReceita)
        .single();

    final etapas = await supabase
        .from('etapa')
        .select()
        .eq('id_receita', widget.idReceita)
        .order('numero_etapa');

    final ingredientes = await supabase
        .from('receita_ingrediente')
        .select(
          'quantidade, unidade, observacao, ingrediente(nome, tipo, orientacao_uso)',
        )
        .eq('id_receita', widget.idReceita);

    final utensilios = await supabase
        .from('receita_utensilio')
        .select(
          'orientacao_uso, utensilio(nome, orientacao_manuseio)',
        )
        .eq('id_receita', widget.idReceita);

    return {
      'receita': receita,
      'etapas': etapas,
      'ingredientes': ingredientes,
      'utensilios': utensilios,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.nomeReceita),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: dadosFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Não foi possível carregar os detalhes da receita.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          dadosFuture = carregarDetalhes();
                        });
                      },
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            );
          }

          final dados = snapshot.data!;

          final receita =
              Map<String, dynamic>.from(dados['receita']);

          final etapas =
              List<Map<String, dynamic>>.from(dados['etapas']);

          final ingredientes =
              List<Map<String, dynamic>>.from(dados['ingredientes']);

          final utensilios =
              List<Map<String, dynamic>>.from(dados['utensilios']);

          final imagemUrl =
              receita['imagem_url']?.toString() ?? '';

          final tempo = receita['tempo_preparo_min'];

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (imagemUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    imagemUrl,
                    height: 220,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        height: 140,
                        color: Colors.orange.shade50,
                        child: const Icon(
                          Icons.restaurant,
                          size: 60,
                          color: Colors.deepOrange,
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                receita['nome']?.toString() ?? 'Receita',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                receita['descricao']?.toString() ??
                    'Sem descrição cadastrada.',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.schedule,
                    color: Colors.deepOrange,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    tempo == null
                        ? 'Tempo não informado'
                        : '$tempo minutos de preparo',
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                'Ingredientes',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (ingredientes.isEmpty)
                const Text('Nenhum ingrediente cadastrado.')
              else
                ...ingredientes.map((item) {
                  final relacao = item['ingrediente'];

                  final ingrediente = relacao is Map
                      ? Map<String, dynamic>.from(relacao)
                      : <String, dynamic>{};

                  final nome =
                      ingrediente['nome']?.toString() ?? 'Ingrediente';

                  final tipo = ingrediente['tipo']?.toString() ?? '';

                  final orientacao =
                      ingrediente['orientacao_uso']?.toString() ?? '';

                  final quantidade = item['quantidade'];

                  final unidade =
                      item['unidade']?.toString() ?? '';

                  final observacao =
                      item['observacao']?.toString() ?? '';

                  final detalhes = [
                    if (quantidade != null) quantidade.toString(),
                    if (unidade.isNotEmpty) unidade,
                    if (observacao.isNotEmpty) observacao,
                  ].join(' ');

                  return ListTile(
                    leading: const Icon(
                      Icons.check_circle_outline,
                      color: Colors.deepOrange,
                    ),
                    title: Text(nome),
                    subtitle: Text([
                      if (detalhes.isNotEmpty) detalhes,
                      if (tipo.isNotEmpty) 'Tipo: $tipo',
                      if (orientacao.isNotEmpty) orientacao,
                    ].join('\n')),
                  );
                }),
              const SizedBox(height: 28),
              Text(
                'Utensílios',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (utensilios.isEmpty)
                const Text('Nenhum utensílio cadastrado.')
              else
                ...utensilios.map((item) {
                  final relacao = item['utensilio'];

                  final utensilio = relacao is Map
                      ? Map<String, dynamic>.from(relacao)
                      : <String, dynamic>{};

                  final nome =
                      utensilio['nome']?.toString() ?? 'Utensílio';

                  final orientacao = item['orientacao_uso'] ??
                      utensilio['orientacao_manuseio'];

                  return ListTile(
                    leading: const Icon(
                      Icons.kitchen,
                      color: Colors.deepOrange,
                    ),
                    title: Text(nome),
                    subtitle: orientacao == null
                        ? null
                        : Text(orientacao.toString()),
                  );
                }),
              const SizedBox(height: 28),
              Text(
                'Modo de preparo',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '${etapas.length} etapas para preparar esta receita.',
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: etapas.isEmpty
                      ? null
                      : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ModoPreparo(
                                nomeReceita: widget.nomeReceita,
                                etapas: etapas,
                              ),
                            ),
                          );
                        },
                  icon: const Icon(Icons.restaurant_menu),
                  label: const Text('Começar preparo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(16),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// MODO DE PREPARO COM TEMPORIZADOR E NOTIFICAÇÃO

class ModoPreparo extends StatefulWidget {
  final String nomeReceita;
  final List<Map<String, dynamic>> etapas;

  const ModoPreparo({
    super.key,
    required this.nomeReceita,
    required this.etapas,
  });

  @override
  State<ModoPreparo> createState() => _ModoPreparoState();
}

class _ModoPreparoState extends State<ModoPreparo>
    with WidgetsBindingObserver {
  int etapaAtual = 0;
  bool concluida = false;

  int minutosSelecionados = 5;
  int segundosRestantes = 5 * 60;

  Timer? temporizador;
  bool temporizadorAtivo = false;
  bool tempoConcluido = false;

  DateTime? horarioTermino;

  String get tempoFormatado {
    final minutos = segundosRestantes ~/ 60;
    final segundos = segundosRestantes % 60;

    return '${minutos.toString().padLeft(2, '0')}:'
        '${segundos.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && temporizadorAtivo) {
      atualizarContagem();
    }
  }

  void atualizarContagem() {
    if (!mounted || !temporizadorAtivo || horarioTermino == null) {
      return;
    }

    final restante =
        horarioTermino!.difference(DateTime.now()).inSeconds;

    if (restante <= 0) {
      temporizador?.cancel();
      temporizador = null;
      horarioTermino = null;

      setState(() {
        segundosRestantes = 0;
        temporizadorAtivo = false;
        tempoConcluido = true;
      });

      cancelarNotificacao().catchError((erro) {
        debugPrint('Erro ao cancelar notificação: $erro');
      });

      return;
    }

    setState(() {
      segundosRestantes = restante;
    });
  }

  Future<void> iniciarTemporizador() async {
    if (segundosRestantes <= 0 || temporizadorAtivo) return;

    final segundos = segundosRestantes;

    horarioTermino =
        DateTime.now().add(Duration(seconds: segundos));

    setState(() {
      temporizadorAtivo = true;
      tempoConcluido = false;
    });

    temporizador?.cancel();

    temporizador = Timer.periodic(
      const Duration(seconds: 1),
      (_) => atualizarContagem(),
    );

    try {
      await agendarNotificacao(widget.nomeReceita, segundos);
    } catch (erro) {
      debugPrint('Erro ao agendar notificação: $erro');
    }
  }

  Future<void> pausarTemporizador() async {
    temporizador?.cancel();
    temporizador = null;

    // Atualiza o tempo antes de pausar.
    if (horarioTermino != null) {
      final restante =
          horarioTermino!.difference(DateTime.now()).inSeconds;

      segundosRestantes = restante > 0 ? restante : 0;
    }

    horarioTermino = null;

    await cancelarNotificacao();

    if (!mounted) return;

    setState(() {
      temporizadorAtivo = false;
      tempoConcluido = segundosRestantes == 0;
    });
  }

  Future<void> reiniciarTemporizador() async {
    temporizador?.cancel();
    temporizador = null;
    horarioTermino = null;

    await cancelarNotificacao();

    if (!mounted) return;

    setState(() {
      temporizadorAtivo = false;
      tempoConcluido = false;
      segundosRestantes = minutosSelecionados * 60;
    });
  }

  Future<void> selecionarDuracao(int minutos) async {
    temporizador?.cancel();
    temporizador = null;
    horarioTermino = null;

    await cancelarNotificacao();

    if (!mounted) return;

    setState(() {
      minutosSelecionados = minutos;
      segundosRestantes = minutos * 60;
      temporizadorAtivo = false;
      tempoConcluido = false;
    });
  }

  Future<void> mudarEtapa(int novaEtapa) async {
    temporizador?.cancel();
    temporizador = null;
    horarioTermino = null;

    await cancelarNotificacao();

    if (!mounted) return;

    setState(() {
      etapaAtual = novaEtapa;
      segundosRestantes = minutosSelecionados * 60;
      temporizadorAtivo = false;
      tempoConcluido = false;
    });
  }

  void voltarEtapa() {
    if (etapaAtual > 0) {
      mudarEtapa(etapaAtual - 1);
    }
  }

  Future<void> avancarEtapa() async {
    if (etapaAtual < widget.etapas.length - 1) {
      await mudarEtapa(etapaAtual + 1);
    } else {
      temporizador?.cancel();
      temporizador = null;
      horarioTermino = null;

      await cancelarNotificacao();

      if (!mounted) return;

      setState(() {
        temporizadorAtivo = false;
        concluida = true;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    temporizador?.cancel();

    cancelarNotificacao().catchError((erro) {
      debugPrint('Erro ao cancelar notificação: $erro');
    });

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalEtapas = widget.etapas.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Modo de preparo'),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
      ),
      body: totalEtapas == 0
          ? const Center(
              child: Text('Esta receita ainda não possui etapas.'),
            )
          : concluida
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: Colors.green,
                          size: 90,
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Receita concluída!',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Parabéns! Você terminou o preparo de '
                          '${widget.nomeReceita}.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () => Navigator.pop(context),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.deepOrange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.all(16),
                            ),
                            child: const Text('Voltar à receita'),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          widget.nomeReceita,
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Etapa ${etapaAtual + 1} de $totalEtapas',
                          style: const TextStyle(
                            color: Colors.deepOrange,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: (etapaAtual + 1) / totalEtapas,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.deepOrange,
                          backgroundColor: Colors.orange.shade100,
                        ),
                        const SizedBox(height: 20),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                Card(
                                  elevation: 3,
                                  child: Padding(
                                    padding: const EdgeInsets.all(22),
                                    child: Column(
                                      children: [
                                        const Icon(
                                          Icons.soup_kitchen,
                                          color: Colors.deepOrange,
                                          size: 52,
                                        ),
                                        const SizedBox(height: 16),
                                        const Text(
                                          'Instrução',
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          widget.etapas[etapaAtual]
                                                      ['instrucao']
                                                  ?.toString() ??
                                              'Sem instrução cadastrada.',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            height: 1.5,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Card(
                                  elevation: 2,
                                  child: Padding(
                                    padding: const EdgeInsets.all(18),
                                    child: Column(
                                      children: [
                                        const Icon(
                                          Icons.timer_outlined,
                                          size: 36,
                                          color: Colors.deepOrange,
                                        ),
                                        const SizedBox(height: 8),
                                        const Text(
                                          'Temporizador',
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          tempoFormatado,
                                          style: TextStyle(
                                            fontSize: 46,
                                            fontWeight: FontWeight.bold,
                                            color: tempoConcluido
                                                ? Colors.green
                                                : Colors.deepOrange,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        DropdownButtonFormField<int>(
                                          value: minutosSelecionados,
                                          decoration: const InputDecoration(
                                            labelText: 'Duração',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: [1, 3, 5, 10, 15, 20, 30]
                                              .map(
                                                (minutos) =>
                                                    DropdownMenuItem<int>(
                                                  value: minutos,
                                                  child: Text(
                                                    '$minutos minuto(s)',
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: temporizadorAtivo
                                              ? null
                                              : (minutos) {
                                                  if (minutos != null) {
                                                    selecionarDuracao(minutos);
                                                  }
                                                },
                                        ),
                                        const SizedBox(height: 12),
                                        if (tempoConcluido)
                                          const Padding(
                                            padding: EdgeInsets.only(
                                              bottom: 10,
                                            ),
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  Icons.check_circle,
                                                  color: Colors.green,
                                                ),
                                                SizedBox(width: 8),
                                                Flexible(
                                                  child: Text(
                                                    'Tempo encerrado!',
                                                    style: TextStyle(
                                                      color: Colors.green,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        Wrap(
                                          alignment: WrapAlignment.center,
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            ElevatedButton.icon(
                                              onPressed: temporizadorAtivo
                                                  ? pausarTemporizador
                                                  : segundosRestantes > 0
                                                      ? iniciarTemporizador
                                                      : null,
                                              icon: Icon(
                                                temporizadorAtivo
                                                    ? Icons.pause
                                                    : Icons.play_arrow,
                                              ),
                                              label: Text(
                                                temporizadorAtivo
                                                    ? 'Pausar'
                                                    : 'Iniciar',
                                              ),
                                            ),
                                            OutlinedButton.icon(
                                              onPressed: reiniciarTemporizador,
                                              icon: const Icon(Icons.refresh),
                                              label: const Text('Reiniciar'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed:
                                    etapaAtual > 0 ? voltarEtapa : null,
                                icon: const Icon(Icons.arrow_back),
                                label: const Text('Anterior'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.all(14),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: avancarEtapa,
                                icon: Icon(
                                  etapaAtual == totalEtapas - 1
                                      ? Icons.check
                                      : Icons.arrow_forward,
                                ),
                                label: Text(
                                  etapaAtual == totalEtapas - 1
                                      ? 'Concluir'
                                      : 'Próxima',
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.deepOrange,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.all(14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}
